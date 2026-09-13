# Analyzes an external Elixir (Mix) or Erlang (Rebar3) project with Argus.
#
# Usage:
#   mix run scripts/analyze_project.exs /path/to/project [analyses...]
#   mix run scripts/analyze_project.exs /path/to/project --json /output.json [analyses...]
#
# Examples:
#   mix run scripts/analyze_project.exs /path/to/project           # run all correctness analyses
#   mix run scripts/analyze_project.exs /path/to/project all       # run every analysis
#   mix run scripts/analyze_project.exs /path/to/project ets       # run one analysis
#   mix run scripts/analyze_project.exs /path/to/project --json /tmp/out.json ets supervision
#
# When --json PATH is provided, all output is written as structured JSON to PATH
# instead of pretty-printing to the console. Per-analysis errors are recorded in
# the JSON rather than halting the script.
#
# The project must already be compiled. This script:
# 1. Adds the project's ebin directories to the code path
# 2. Discovers project modules (skipping deps)
# 3. Runs the specified analyses (default: all correctness/bug-detection analyses)
# 4. Pretty-prints supervision structure and findings (or writes JSON)

defmodule Argus.Scripts.AnalyzeProject do
  # Default set of analyses to run when none are specified. These are the
  # BEAM/OTP correctness checks; pass `all` to run every available analysis.
  @correctness_analyses [
    :atom_safety,
    :call_cycle,
    :deferred_startup_deadlock,
    :distributed,
    :error_handling,
    :ets,
    :gen_statem,
    :one_for_one_coupling,
    :process_bottleneck,
    :process_registry,
    :supervision,
    :sync_call_in_init,
    :timeout_chain,
    :unlinked_spawn,
    :unsafe_task
  ]

  @doc false
  def run(args) do
    {opts, positional} = parse_opts(args)
    {project_path, analyses} = parse_positional(positional)
    project_path = Path.expand(project_path)

    unless File.dir?(project_path) do
      abort("Project path does not exist: #{project_path}")
    end

    json_path = opts[:json]

    unless json_path, do: IO.puts("Analyzing: #{project_path}")
    unless json_path, do: IO.puts("Analyses:  #{Enum.map_join(analyses, ", ", &to_string/1)}")
    unless json_path, do: IO.puts("")

    # Add project ebin dirs to code path.
    ebin_dirs = discover_ebin_dirs(project_path)

    if ebin_dirs == [] do
      abort("No ebin directories found. Is the project compiled?")
    end

    Enum.each(ebin_dirs, fn dir ->
      Code.prepend_path(dir)
    end)

    unless json_path, do: IO.puts("Added #{length(ebin_dirs)} ebin directories to code path")

    # Discover project modules (from the project's own ebins, not deps).
    project_ebins = find_project_ebins(project_path)
    modules = Enum.flat_map(project_ebins, &discover_modules/1) |> Enum.sort()

    if modules == [] do
      abort("No modules found in project ebin")
    end

    unless json_path, do: IO.puts("Found #{length(modules)} project modules")
    unless json_path, do: IO.puts("")

    if json_path do
      run_json(project_path, modules, analyses, json_path)
    else
      run_pretty(project_path, modules, analyses)
    end
  end

  # JSON output mode — collects all results (including errors) and writes JSON.
  #
  # Two views of the same run land in the report: the raw relation rows
  # ("analyses") and severity-ranked findings with line-resolved anchors
  # ("otp_findings", the reviewable interface for triage across projects).
  defp run_json(project_path, modules, analyses, json_path) do
    start_time = System.monotonic_time(:millisecond)

    facts_dir = extract!(modules, analyses)

    analysis_results =
      Enum.map(analyses, fn analysis -> {analysis, run_rules(facts_dir, analysis)} end)

    findings =
      case analyses -- [:coverage] do
        [] ->
          nil

        findings_analyses ->
          case Argus.Findings.run(modules, analyses: findings_analyses, facts_dir: facts_dir) do
            {:ok, findings} -> findings
            {:error, _reason} -> nil
          end
      end

    lines = Argus.Lines.from_facts_dir(facts_dir)
    File.rm_rf(Path.dirname(facts_dir))

    duration_ms = System.monotonic_time(:millisecond) - start_time

    meta = %{
      "name" => Path.basename(project_path),
      "path" => project_path,
      "build_system" => detect_build_system(project_path),
      "module_count" => length(modules),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "duration_ms" => duration_ms
    }

    report =
      Argus.Report.build_project_report(meta, analysis_results,
        findings: findings,
        lines: findings && lines
      )

    case Argus.Report.write_json(report, json_path) do
      :ok -> :ok
      {:error, reason} -> abort("Failed to write JSON: #{inspect(reason)}")
    end
  end

  # Pretty-print mode — original behavior.
  defp run_pretty(_project_path, modules, analyses) do
    # Print supervision structure first.
    print_supervision_structure(modules)

    # One extraction for every analysis, then a solve each.
    facts_dir = extract!(modules, analyses)
    {results, failures} = run_analyses_pretty(facts_dir, analyses)
    lines = Argus.Lines.from_facts_dir(facts_dir)
    File.rm_rf(Path.dirname(facts_dir))

    # Print results grouped by analysis, with anchors resolved to lines.
    print_all_results(results, lines)

    # Print summary.
    print_summary(results, failures)

    if failures != [] do
      System.halt(1)
    end
  end

  defp parse_opts(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [json: :string])

    {opts, positional}
  end

  defp parse_positional([project_path | rest]) do
    analyses = parse_analysis_args(rest)
    {project_path, analyses}
  end

  defp parse_positional(_) do
    abort("""
    Usage: mix run scripts/analyze_project.exs /path/to/project [--json PATH] [analyses...]

    When no analyses are specified, runs all correctness analyses:
      #{Enum.map_join(@correctness_analyses, ", ", &to_string/1)}

    Pass "all" to run every available analysis.

    Options:
      --json PATH   Write structured JSON results to PATH instead of console output\
    """)
  end

  defp parse_analysis_args([]), do: @correctness_analyses

  defp parse_analysis_args(["all"]), do: Enum.sort(Argus.Analysis.builtin_analyses())

  defp parse_analysis_args(names) do
    builtin = Argus.Analysis.builtin_analyses()

    Enum.map(names, fn name ->
      case Enum.find(builtin, &(to_string(&1) == name)) do
        nil ->
          abort(
            "Unknown analysis: #{name}\nAvailable: #{Enum.map_join(builtin, ", ", &to_string/1)}"
          )

        analysis ->
          analysis
      end
    end)
  end

  defp extract!(modules, analyses) do
    unless Argus.Souffle.available?(), do: abort(Argus.Souffle.not_found_message())

    case Argus.Analysis.extract_facts(modules, analyses) do
      {:ok, facts_dir} -> facts_dir
      {:error, reason} -> abort("Extraction failed: #{inspect(reason)}")
    end
  end

  defp run_rules(facts_dir, analysis) do
    with {:ok, results} <- Argus.Analysis.run_rules(facts_dir, analysis) do
      {:ok, Argus.Analysis.filter_to_outputs(results, analysis)}
    end
  end

  defp run_analyses_pretty(facts_dir, analyses) do
    analyses
    |> Enum.reduce({[], []}, fn analysis, {ok_acc, err_acc} ->
      IO.puts("--- Running #{analysis} ---")

      case run_rules(facts_dir, analysis) do
        {:ok, results} ->
          {[{analysis, dedupe_results(analysis, results)} | ok_acc], err_acc}

        {:error, reason} ->
          IO.puts(:stderr, "  Error: #{inspect(reason)}")
          {ok_acc, [{analysis, reason} | err_acc]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  defp print_all_results(results, lines) do
    IO.puts("")

    Enum.each(results, fn {analysis, result} ->
      print_results(result, analysis, lines)
    end)
  end

  # Relations with witness columns yield one row per witnessing site;
  # collapse to logical findings (the same identity rule as
  # Argus.Findings) so printed rows and summary counts stay stable.
  defp dedupe_results(analysis, results) do
    case Argus.Analysis.output_relations(analysis) do
      {:ok, relations} ->
        by_name = Map.new(relations, &{Atom.to_string(&1.name), &1})

        Map.new(results, fn {name, rows} ->
          case by_name do
            %{^name => relation} -> {name, Argus.Findings.dedupe_rows(relation, rows)}
            _ -> {name, rows}
          end
        end)

      :error ->
        results
    end
  end

  defp print_summary(results, failures) do
    IO.puts("--- Summary ---")
    IO.puts("")

    total_findings = 0

    total_findings =
      Enum.reduce(results, total_findings, fn {analysis, result}, acc ->
        allowed = output_relation_names(analysis)

        count =
          result
          |> then(fn rs ->
            if allowed, do: Enum.filter(rs, fn {name, _} -> name in allowed end), else: rs
          end)
          |> Enum.reject(fn {_, rows} -> rows == [] end)
          |> Enum.map(fn {_, rows} -> length(rows) end)
          |> Enum.sum()

        label = if count == 0, do: "pass", else: "#{count} finding(s)"
        IO.puts("  #{to_string(analysis)}: #{label}")
        acc + count
      end)

    Enum.each(failures, fn {analysis, reason} ->
      IO.puts("  #{to_string(analysis)}: FAILED (#{inspect(reason)})")
    end)

    IO.puts("")

    cond do
      failures != [] ->
        IO.puts("#{length(failures)} analysis(es) failed, #{total_findings} total finding(s).")

      total_findings == 0 ->
        IO.puts("All clear — no findings across #{length(results)} analysis(es).")

      true ->
        IO.puts("#{total_findings} total finding(s) across #{length(results)} analysis(es).")
    end

    IO.puts("")
  end

  defp discover_ebin_dirs(project_path) do
    # Find all ebin dirs under _build.
    Path.join([project_path, "_build", "**", "ebin"])
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
  end

  defp find_project_ebins(project_path) do
    apps_dir = Path.join(project_path, "apps")

    app_names =
      if File.dir?(apps_dir) do
        # Umbrella / multi-app project — each subdir under apps/ is a project app.
        apps_dir
        |> File.ls!()
        |> Enum.filter(fn name ->
          File.dir?(Path.join(apps_dir, name))
        end)
      else
        [detect_app_name(project_path)]
      end

    # Any build env counts — projects with build_per_environment: false
    # compile into _build/shared, and custom envs are legal. Prefer dev
    # when several exist, else take whichever is present.
    env_preference = ["dev", "shared", "prod", "default"]

    ebins =
      Enum.flat_map(app_names, fn app ->
        Path.join([project_path, "_build", "*", "lib", app, "ebin"])
        |> Path.wildcard()
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort_by(fn path ->
          env = path |> Path.split() |> Enum.at(-4)
          Enum.find_index(env_preference, &(&1 == env)) || length(env_preference)
        end)
        |> Enum.take(1)
      end)

    if ebins == [] do
      app_label = Enum.join(app_names, ", ")
      abort("Could not find project ebin directories for apps: #{app_label}")
    end

    ebins
  end

  defp detect_app_name(project_path) do
    cond do
      File.exists?(Path.join(project_path, "mix.exs")) ->
        detect_app_name_mix(project_path)

      app_src = find_app_src(project_path) ->
        detect_app_name_rebar(app_src)

      true ->
        Path.basename(project_path)
    end
  end

  defp detect_app_name_mix(project_path) do
    content = File.read!(Path.join(project_path, "mix.exs"))

    case Regex.run(~r/app:\s*:(\w+)/, content) do
      [_, name] -> name
      _ -> Path.basename(project_path)
    end
  end

  defp find_app_src(project_path) do
    Path.join(project_path, "src/*.app.src")
    |> Path.wildcard()
    |> List.first()
  end

  defp detect_app_name_rebar(app_src_path) do
    app_src_path
    |> Path.basename(".app.src")
  end

  defp detect_build_system(project_path) do
    cond do
      File.exists?(Path.join(project_path, "mix.exs")) -> "mix"
      File.exists?(Path.join(project_path, "rebar.config")) -> "rebar3"
      true -> "unknown"
    end
  end

  defp discover_modules(ebin_dir) do
    ebin_dir
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      path
      |> Path.basename(".beam")
      |> String.to_atom()
    end)
    |> Enum.sort()
  end

  defp print_supervision_structure(modules) do
    IO.puts("--- Supervision structure ---")
    IO.puts("")

    Enum.each(modules, fn mod ->
      path = to_string(:code.which(mod))

      case BeamSpy.BeamFile.disassemble(path) do
        {:ok, data} ->
          facts = Argus.Extractors.Supervision.extract(data)

          if Map.has_key?(facts, :supervisor) do
            [mod_str, strategy, _site] = hd(facts[:supervisor])
            IO.puts("  #{mod_str} (#{strategy})")

            children = Map.get(facts, :supervisor_child, [])

            children
            |> Enum.sort_by(fn [_, pos | _] -> String.to_integer(pos) end)
            |> Enum.each(fn [_, pos, child, restart, type] ->
              IO.puts("    #{pos}. #{child} (#{restart}, #{type})")
            end)

            IO.puts("")
          end

        {:error, _} ->
          :skip
      end
    end)
  end

  # Filter results to only output relations declared by the analysis module.
  # Intermediate relations (call_edge, cfg_edge, etc.) are excluded when the
  # analysis declares its outputs.
  defp print_results(results, analysis, lines) do
    allowed = output_relation_names(analysis)

    findings =
      results
      |> then(fn rs ->
        if allowed, do: Enum.filter(rs, fn {name, _} -> name in allowed end), else: rs
      end)
      |> Enum.reject(fn {_, rows} -> rows == [] end)

    if findings == [] do
      :ok
    else
      IO.puts("=== #{analysis} ===")
      IO.puts("")

      findings
      |> Enum.sort_by(fn {name, _} -> name end)
      |> Enum.each(fn {relation, rows} ->
        IO.puts("  #{relation} (#{length(rows)} findings)")
        IO.puts("")

        Enum.each(rows, fn row ->
          IO.puts("    #{Enum.map_join(row, "  |  ", &annotate_cell(&1, lines))}")
        end)

        IO.puts("")
      end)
    end
  end

  # Cells holding instruction or function IDs resolve to a source line;
  # anything else passes through untouched.
  defp annotate_cell(cell, lines) do
    case Argus.Lines.resolve(lines, cell) do
      nil -> cell
      line -> "#{cell} (line #{line})"
    end
  end

  defp output_relation_names(analysis) do
    case Argus.Analysis.output_relations(analysis) do
      {:ok, relations} -> Enum.map(relations, &Atom.to_string(&1.name))
      :error -> nil
    end
  end

  defp abort(msg) do
    IO.puts(:stderr, "Error: #{msg}")
    System.halt(1)
  end
end

Argus.Scripts.AnalyzeProject.run(System.argv())
