# Analyzes an external Elixir (Mix) or Erlang (Rebar3) project with Argus.
#
# Usage:
#   mix run scripts/analyze_project.exs /path/to/project [analyses...]
#
# Examples:
#   mix run scripts/analyze_project.exs /path/to/project           # run all correctness analyses
#   mix run scripts/analyze_project.exs /path/to/project all       # run every analysis
#   mix run scripts/analyze_project.exs /path/to/project ets       # run one analysis
#   mix run scripts/analyze_project.exs /path/to/project ets supervision  # run several
#
# The project must already be compiled. This script:
# 1. Adds the project's ebin directories to the code path
# 2. Discovers project modules (skipping deps)
# 3. Runs the specified analyses (default: all correctness/bug-detection analyses)
# 4. Pretty-prints supervision structure and findings

defmodule Argus.Scripts.AnalyzeProject do
  # Analyses that detect bugs, correctness issues, or anti-patterns.
  # Structural/informational analyses (cfg, callgraph, reachability,
  # reaching_def, liveness, tail_call, message_flow) are excluded
  # from the default set.
  @correctness_analyses [
    :call_cycle,
    :ets,
    :one_for_one_coupling,
    :process_bottleneck,
    :supervision,
    :sync_call_in_init,
    :unlinked_spawn,
    :unsafe_task
  ]

  @doc false
  def run(args) do
    {project_path, analyses} = parse_args(args)
    project_path = Path.expand(project_path)

    unless File.dir?(project_path) do
      abort("Project path does not exist: #{project_path}")
    end

    IO.puts("Analyzing: #{project_path}")

    IO.puts("Analyses:  #{Enum.map_join(analyses, ", ", &to_string/1)}")

    IO.puts("")

    # Add project ebin dirs to code path.
    ebin_dirs = discover_ebin_dirs(project_path)

    if ebin_dirs == [] do
      abort("No ebin directories found. Is the project compiled?")
    end

    Enum.each(ebin_dirs, fn dir ->
      Code.prepend_path(dir)
    end)

    IO.puts("Added #{length(ebin_dirs)} ebin directories to code path")

    # Discover project modules (from the project's own ebins, not deps).
    project_ebins = find_project_ebins(project_path)
    modules = Enum.flat_map(project_ebins, &discover_modules/1) |> Enum.sort()

    if modules == [] do
      abort("No modules found in project ebin")
    end

    IO.puts("Found #{length(modules)} project modules")
    IO.puts("")

    # Print supervision structure first.
    print_supervision_structure(modules)

    # Run each analysis and collect results.
    {results, failures} = run_analyses(modules, analyses)

    # Print results grouped by analysis.
    print_all_results(results)

    # Print summary.
    print_summary(results, failures)

    if failures != [] do
      System.halt(1)
    end
  end

  defp parse_args([project_path | rest]) do
    analyses = parse_analysis_args(rest)
    {project_path, analyses}
  end

  defp parse_args(_) do
    abort("""
    Usage: mix run scripts/analyze_project.exs /path/to/project [analyses...]

    When no analyses are specified, runs all correctness analyses:
      #{Enum.map_join(@correctness_analyses, ", ", &to_string/1)}

    Pass "all" to run every available analysis.\
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

  defp run_analyses(modules, analyses) do
    analyses
    |> Enum.reduce({[], []}, fn analysis, {ok_acc, err_acc} ->
      IO.puts("--- Running #{analysis} ---")

      case Argus.analyze(modules, analysis) do
        {:ok, results} ->
          {[{analysis, results} | ok_acc], err_acc}

        {:error, reason} ->
          IO.puts(:stderr, "  Error: #{inspect(reason)}")
          {ok_acc, [{analysis, reason} | err_acc]}
      end
    end)
    |> then(fn {ok, err} -> {Enum.reverse(ok), Enum.reverse(err)} end)
  end

  defp print_all_results(results) do
    IO.puts("")

    Enum.each(results, fn {analysis, result} ->
      print_results(result, analysis)
    end)
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

    build_envs = ["dev", "prod", "default"]

    ebins =
      Enum.flat_map(app_names, fn app ->
        build_envs
        |> Enum.map(fn env ->
          Path.join([project_path, "_build", env, "lib", app, "ebin"])
        end)
        |> Enum.find(&File.dir?/1)
        |> List.wrap()
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
            [mod_str, strategy] = hd(facts[:supervisor])
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
  defp print_results(results, analysis) do
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
          IO.puts("    #{Enum.join(row, "  |  ")}")
        end)

        IO.puts("")
      end)
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
