# Parallel analysis harness for running Argus against many projects.
#
# Usage:
#   mix run scripts/harness.exs INPUT_DIR OUTPUT_DIR [options]
#
# Options:
#   --concurrency N     Parallel project pipelines (default: 4)
#   --skip-compile      Assume projects already compiled
#   --resume            Skip projects with existing results.json
#   --analyses a,b,c    Comma-separated analysis names (default: correctness set)
#   --timeout N         Per-project timeout in seconds (default: 900)
#
# Each project is analyzed in a separate OS process (via mix run analyze_project.exs)
# because Code.prepend_path modifies global VM state. The harness parallelizes at the
# project level using Task.async_stream.
#
# Output:
#   output/
#   ├── manifest.json       # run metadata, per-project status
#   ├── triage.json         # cross-project index by finding type
#   ├── phoenix/
#   │   ├── results.json    # full analysis results
#   │   └── compile.log     # compilation output
#   └── ...

defmodule Argus.Scripts.Harness do
  @default_timeout 900

  # Parallel measurement primitive lives in Argus.Autoresearch.Measure
  # so the autoresearch loop and the harness share one subprocess-
  # fanout implementation. Ebin discovery happens at runtime there
  # via :code.get_path/0.
  alias Argus.Autoresearch.Measure

  def run(args) do
    {opts, positional} = parse_opts(args)
    {input_dir, output_dir} = parse_positional(positional)

    input_dir = Path.expand(input_dir)
    output_dir = Path.expand(output_dir)

    unless File.dir?(input_dir) do
      abort("Input directory does not exist: #{input_dir}")
    end

    File.mkdir_p!(output_dir)

    concurrency = opts[:concurrency]
    skip_compile = opts[:skip_compile]
    resume = opts[:resume]
    analyses = opts[:analyses]
    timeout = opts[:timeout]

    IO.puts("Argus parallel analysis harness")
    IO.puts("  Input:       #{input_dir}")
    IO.puts("  Output:      #{output_dir}")
    IO.puts("  Concurrency: #{concurrency}")
    IO.puts("  Analyses:    #{Enum.join(analyses, ", ")}")
    IO.puts("  Timeout:     #{timeout}s per project")
    if skip_compile, do: IO.puts("  Skip compile: yes")
    if resume, do: IO.puts("  Resume mode:  yes")
    IO.puts("")

    # Discover projects.
    projects = discover_projects(input_dir)

    if projects == [] do
      abort("No Mix or Rebar3 projects found in #{input_dir}")
    end

    IO.puts("Found #{length(projects)} projects")

    # Filter already-analyzed projects when resuming.
    projects =
      if resume do
        projects
        |> Enum.reject(fn {name, _path, _build} ->
          File.exists?(Path.join([output_dir, name, "results.json"]))
        end)
        |> tap(fn remaining ->
          skipped = length(discover_projects(input_dir)) - length(remaining)
          if skipped > 0, do: IO.puts("Skipping #{skipped} already-analyzed projects")
        end)
      else
        projects
      end

    IO.puts("Analyzing #{length(projects)} projects")
    IO.puts("")

    total = length(projects)
    start_time = System.monotonic_time(:millisecond)

    # Run analysis pipeline per project with bounded concurrency.
    project_statuses =
      projects
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {{name, path, build_system}, index} ->
          project_out_dir = Path.join(output_dir, name)
          File.mkdir_p!(project_out_dir)

          result =
            analyze_project(name, path, build_system, project_out_dir, %{
              skip_compile: skip_compile,
              analyses: analyses,
              timeout: timeout
            })

          print_progress(index, total, name, result)
          {name, result}
        end,
        max_concurrency: concurrency,
        timeout: (timeout + 60) * 1_000,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, {name, result}} -> {name, result}
        {:exit, :timeout} -> {"unknown", {:error, "harness timeout"}}
      end)
      |> Map.new()

    total_duration_ms = System.monotonic_time(:millisecond) - start_time

    # Generate aggregate reports.
    manifest =
      build_manifest(input_dir, output_dir, analyses, concurrency, projects, project_statuses)

    triage = build_triage(output_dir, project_statuses)

    Argus.Report.write_json(manifest, Path.join(output_dir, "manifest.json"))
    Argus.Report.write_json(triage, Path.join(output_dir, "triage.json"))

    # Print summary.
    IO.puts("")
    IO.puts("═══════════════════════════════════════════")
    IO.puts("  Harness complete")
    IO.puts("═══════════════════════════════════════════")
    IO.puts("")

    stats = manifest["stats"]
    IO.puts("  Total:    #{stats["total"]}")
    IO.puts("  Analyzed: #{stats["analyzed"]}")
    IO.puts("  Failed:   #{stats["failed"]}")
    IO.puts("  Skipped:  #{stats["skipped"]}")
    IO.puts("  Duration: #{Float.round(total_duration_ms / 1_000, 1)}s")
    IO.puts("")
    IO.puts("  manifest.json: #{Path.join(output_dir, "manifest.json")}")
    IO.puts("  triage.json:   #{Path.join(output_dir, "triage.json")}")
    IO.puts("")
  end

  defp parse_opts(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          concurrency: :integer,
          skip_compile: :boolean,
          resume: :boolean,
          analyses: :string,
          timeout: :integer
        ],
        aliases: [c: :concurrency, t: :timeout]
      )

    # Each project spawns a full BEAM VM + Souffle, so keep concurrency low
    # to avoid exhausting system memory.
    concurrency = opts[:concurrency] || 4
    timeout = opts[:timeout] || @default_timeout
    skip_compile = opts[:skip_compile] || false
    resume = opts[:resume] || false

    # Default to every shipped analysis except coverage (which measures
    # the extractor pipeline, not the analyzed code). Discovered at
    # runtime so the harness never lags behind newly-added analyses.
    analyses =
      case opts[:analyses] do
        nil ->
          Argus.Analysis.builtin_analyses()
          |> List.delete(:coverage)
          |> Enum.map(&Atom.to_string/1)
          |> Enum.sort()

        str ->
          String.split(str, ",", trim: true)
      end

    parsed = %{
      concurrency: concurrency,
      timeout: timeout,
      skip_compile: skip_compile,
      resume: resume,
      analyses: analyses
    }

    {parsed, positional}
  end

  defp parse_positional([input_dir, output_dir]) do
    {input_dir, output_dir}
  end

  defp parse_positional(_) do
    abort("""
    Usage: mix run scripts/harness.exs INPUT_DIR OUTPUT_DIR [options]

    Options:
      --concurrency N     Parallel project pipelines (default: 4)
      --skip-compile      Assume projects already compiled
      --resume            Skip projects with existing results.json
      --analyses a,b,c    Comma-separated analysis names (default: correctness set)
      --timeout N         Per-project timeout in seconds (default: 900)\
    """)
  end

  defp discover_projects(input_dir) do
    input_dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(input_dir, name)

      cond do
        not File.dir?(path) ->
          []

        File.exists?(Path.join(path, "mix.exs")) ->
          [{name, path, "mix"}]

        File.exists?(Path.join(path, "rebar.config")) ->
          [{name, path, "rebar3"}]

        true ->
          []
      end
    end)
  end

  # Runs the full pipeline for a single project: compile → analyze.
  defp analyze_project(name, path, build_system, out_dir, opts) do
    compile_log_path = Path.join(out_dir, "compile.log")
    results_path = Path.join(out_dir, "results.json")
    start_time = System.monotonic_time(:millisecond)

    # Step 1: compile (unless --skip-compile).
    compile_result =
      if opts.skip_compile do
        :ok
      else
        compile_project(path, build_system, compile_log_path)
      end

    case compile_result do
      :ok ->
        # Step 2: run analysis in a subprocess.
        case run_analysis_subprocess(path, results_path, opts) do
          :ok ->
            duration_ms = System.monotonic_time(:millisecond) - start_time
            read_project_result(name, results_path, duration_ms)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp compile_project(path, "mix", compile_log_path) do
    # Use File.stream! to write raw bytes — IO.stream goes through Erlang's
    # IO protocol which crashes on non-latin1 output.
    File.write!(compile_log_path, "")
    log = File.stream!(compile_log_path, [:append])

    case System.cmd("mix", ["deps.get", "--quiet"],
           cd: path,
           stderr_to_stdout: true,
           into: log
         ) do
      {_, 0} ->
        case System.cmd("mix", ["compile", "--quiet"],
               cd: path,
               stderr_to_stdout: true,
               into: log
             ) do
          {_, 0} -> :ok
          {_, _} -> {:error, "compile_failed"}
        end

      {_, _} ->
        {:error, "deps_get_failed"}
    end
  end

  defp compile_project(path, "rebar3", compile_log_path) do
    File.write!(compile_log_path, "")
    log = File.stream!(compile_log_path, [:append])

    case System.cmd("rebar3", ["compile"],
           cd: path,
           stderr_to_stdout: true,
           into: log
         ) do
      {_, 0} -> :ok
      {_, _} -> {:error, "compile_failed"}
    end
  end

  defp run_analysis_subprocess(project_path, results_path, opts) do
    # Delegate to the shared Measure primitive so harness and the
    # autoresearch loop use identical subprocess invocation logic.
    case Measure.run_analysis_subprocess(project_path, results_path, opts.analyses) do
      :ok ->
        :ok

      {:error, {:no_output, error_log}} ->
        {:error, "subprocess exited 0 but no results.json produced (see #{error_log})"}

      {:error, {:exit_code, code, error_log}} ->
        {:error, "analyze_project exited with code #{code} (see #{error_log})"}

      {:error, reason} ->
        {:error, "analyze_project failed: #{inspect(reason)}"}
    end
  end

  # Reads just the summary from results.json — avoids holding the full report
  # in memory across all projects simultaneously.
  defp read_project_result(name, results_path, duration_ms) do
    case File.read(results_path) do
      {:ok, json} ->
        case :json.decode(json) do
          report when is_map(report) ->
            total_findings = get_in(report, ["summary", "total_findings"]) || 0

            {:ok,
             %{
               "name" => name,
               "total_findings" => total_findings,
               "duration_ms" => duration_ms
             }}

          _ ->
            {:error, "invalid JSON in results.json"}
        end

      {:error, reason} ->
        {:error, "could not read results.json: #{inspect(reason)}"}
    end
  end

  defp print_progress(index, total, name, result) do
    label =
      case result do
        {:ok, info} ->
          findings = info["total_findings"]
          duration = Float.round(info["duration_ms"] / 1_000, 1)
          "#{findings} finding(s) (#{duration}s)"

        {:error, reason} ->
          "FAILED: #{reason}"
      end

    IO.puts("[#{index}/#{total}] #{name}: #{label}")
  end

  defp build_manifest(input_dir, output_dir, analyses, concurrency, all_projects, statuses) do
    total = length(all_projects)

    project_entries =
      Map.new(statuses, fn {name, result} ->
        entry =
          case result do
            {:ok, info} ->
              %{
                "status" => "ok",
                "total_findings" => info["total_findings"],
                "duration_ms" => info["duration_ms"]
              }

            {:error, reason} ->
              %{"status" => "failed", "error" => reason}
          end

        {name, entry}
      end)

    analyzed = Enum.count(statuses, fn {_, r} -> match?({:ok, _}, r) end)
    failed = Enum.count(statuses, fn {_, r} -> match?({:error, _}, r) end)
    skipped = total - map_size(statuses)

    %{
      "run" => %{
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "input_dir" => input_dir,
        "output_dir" => output_dir,
        "analyses" => analyses,
        "concurrency" => concurrency
      },
      "stats" => %{
        "total" => total,
        "analyzed" => analyzed,
        "failed" => failed,
        "skipped" => skipped
      },
      "projects" => project_entries
    }
  end

  # Severity rank for sorting triage entries most-urgent-first.
  @severity_rank %{"error" => 0, "warning" => 1, "info" => 2}

  # How many findings to inline in triage.json. Everything is still in the
  # per-project results.json — this is the cross-project review surface.
  @triage_findings_cap 200

  defp build_triage(output_dir, statuses) do
    # Collect findings by reading each project's results.json from disk one at
    # a time, so we never hold all reports in memory simultaneously.
    per_project =
      statuses
      |> Enum.flat_map(fn {name, result} ->
        case result do
          {:ok, _} ->
            results_path = Path.join([output_dir, name, "results.json"])
            [extract_project_triage(name, results_path)]

          {:error, _} ->
            []
        end
      end)

    by_analysis =
      per_project
      |> Enum.flat_map(fn %{name: project, findings: findings} ->
        Enum.map(findings, &{&1["analysis"], project, &1["severity"]})
      end)
      |> Enum.group_by(fn {analysis, _project, _severity} -> analysis end)
      |> Map.new(fn {analysis, entries} ->
        severities =
          entries |> Enum.frequencies_by(fn {_, _, severity} -> severity end)

        projects =
          entries |> Enum.map(fn {_, project, _} -> project end) |> Enum.uniq() |> Enum.sort()

        {analysis,
         %{
           "total_findings" => length(entries),
           "by_severity" => severities,
           "projects" => projects
         }}
      end)

    by_project =
      per_project
      |> Enum.map(fn %{name: name, findings: findings} ->
        %{
          "name" => name,
          "total_findings" => length(findings),
          "by_severity" => Enum.frequencies_by(findings, & &1["severity"])
        }
      end)
      |> Enum.sort_by(& &1["total_findings"], :desc)

    # The reviewable index: every finding across the corpus, most severe
    # first, capped. Detail prose stays in the per-project results.json.
    findings_index =
      per_project
      |> Enum.flat_map(fn %{name: project, findings: findings} ->
        Enum.map(findings, fn f ->
          f
          |> Map.take(["analysis", "severity", "title", "module", "mfa", "line"])
          |> Map.put("project", project)
        end)
      end)
      |> Enum.sort_by(fn f -> {@severity_rank[f["severity"]] || 3, f["project"], f["title"]} end)
      |> Enum.take(@triage_findings_cap)

    %{
      "by_analysis" => by_analysis,
      "by_project" => by_project,
      "findings" => findings_index
    }
  end

  # Reads a single results.json and returns the project's findings for
  # triage. Prefers the severity-ranked "otp_findings" section; falls back
  # to synthesizing entries from raw relation counts for reports produced
  # by older runs. The file is read and discarded per-project.
  defp extract_project_triage(project_name, results_path) do
    case File.read(results_path) do
      {:ok, json} ->
        report = :json.decode(json)

        findings =
          case report do
            %{"otp_findings" => %{"findings" => findings}} ->
              findings

            %{"analyses" => analyses} ->
              Enum.flat_map(analyses, fn {analysis_name, entry} ->
                count = entry["finding_count"] || 0

                List.duplicate(
                  %{"analysis" => analysis_name, "severity" => "info", "title" => "(raw row)"},
                  count
                )
              end)

            _ ->
              []
          end

        %{name: project_name, findings: findings}

      {:error, _} ->
        %{name: project_name, findings: []}
    end
  end

  defp abort(msg) do
    IO.puts(:stderr, "Error: #{msg}")
    System.halt(1)
  end
end

Argus.Scripts.Harness.run(System.argv())
