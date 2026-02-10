# Parallel analysis harness for running Argus against many projects.
#
# Usage:
#   mix run scripts/harness.exs INPUT_DIR OUTPUT_DIR [options]
#
# Options:
#   --concurrency N     Parallel project pipelines (default: schedulers_online)
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
  @argus_dir File.cwd!()

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

    concurrency = opts[:concurrency] || System.schedulers_online()
    timeout = opts[:timeout] || @default_timeout
    skip_compile = opts[:skip_compile] || false
    resume = opts[:resume] || false

    analyses =
      case opts[:analyses] do
        nil ->
          ~w(call_cycle ets one_for_one_coupling process_bottleneck supervision sync_call_in_init unlinked_spawn unsafe_task)

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
      --concurrency N     Parallel project pipelines (default: schedulers_online)
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
    case System.cmd("mix", ["deps.get", "--quiet"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case System.cmd("mix", ["compile", "--quiet"],
               cd: path,
               stderr_to_stdout: true
             ) do
          {compile_output, 0} ->
            File.write!(compile_log_path, output <> compile_output)
            :ok

          {compile_output, _} ->
            File.write!(compile_log_path, output <> compile_output)
            {:error, "compile_failed"}
        end

      {output, _} ->
        File.write!(compile_log_path, output)
        {:error, "deps_get_failed"}
    end
  end

  defp compile_project(path, "rebar3", compile_log_path) do
    case System.cmd("rebar3", ["compile"],
           cd: path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        File.write!(compile_log_path, output)
        :ok

      {output, _} ->
        File.write!(compile_log_path, output)
        {:error, "compile_failed"}
    end
  end

  defp run_analysis_subprocess(project_path, results_path, opts) do
    script = Path.join(@argus_dir, "scripts/analyze_project.exs")
    args = ["run", script, project_path, "--json", results_path | opts.analyses]

    # System.cmd doesn't support :timeout — we rely on Task.async_stream's
    # timeout to kill long-running subprocesses.
    case System.cmd("mix", args,
           cd: @argus_dir,
           stderr_to_stdout: true,
           env: [{"MIX_ENV", "dev"}]
         ) do
      {_output, 0} ->
        :ok

      {output, code} ->
        {:error, "analyze_project exited with code #{code}: #{String.slice(output, 0, 500)}"}
    end
  end

  # Reads the results.json produced by the subprocess.
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
               "duration_ms" => duration_ms,
               "report" => report
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

  defp build_triage(output_dir, statuses) do
    # Collect findings across all successful projects.
    by_analysis =
      statuses
      |> Enum.flat_map(fn {name, result} ->
        case result do
          {:ok, info} ->
            report = info["report"]
            analyses = report["analyses"] || %{}

            Enum.flat_map(analyses, fn {analysis_name, entry} ->
              findings = entry["findings"] || %{}

              count =
                findings
                |> Map.values()
                |> Enum.map(&length/1)
                |> Enum.sum()

              if count > 0 do
                [{analysis_name, name, count}]
              else
                []
              end
            end)

          {:error, _} ->
            []
        end
      end)
      |> Enum.group_by(fn {analysis, _project, _count} -> analysis end)
      |> Map.new(fn {analysis, entries} ->
        total = Enum.map(entries, fn {_, _, count} -> count end) |> Enum.sum()
        projects = Enum.map(entries, fn {_, project, _} -> project end) |> Enum.sort()
        {analysis, %{"total_findings" => total, "projects" => projects}}
      end)

    # Per-project totals sorted descending by finding count.
    by_project =
      statuses
      |> Enum.flat_map(fn {name, result} ->
        case result do
          {:ok, info} ->
            [%{"name" => name, "total_findings" => info["total_findings"]}]

          {:error, _} ->
            []
        end
      end)
      |> Enum.sort_by(& &1["total_findings"], :desc)

    # Read per-project results.json for the analysis-level detail.
    # We already have reports in memory so we use those instead of re-reading.

    %{
      "by_analysis" => by_analysis,
      "by_project" => by_project
    }
  end

  defp abort(msg) do
    IO.puts(:stderr, "Error: #{msg}")
    System.halt(1)
  end
end

Argus.Scripts.Harness.run(System.argv())
