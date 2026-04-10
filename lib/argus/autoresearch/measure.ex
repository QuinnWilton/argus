defmodule Argus.Autoresearch.Measure do
  @moduledoc """
  Parallel corpus measurement via per-project subprocesses.

  Runs `scripts/analyze_project.exs` once per project in a separate
  `elixir` VM, collects the resulting JSON reports, and returns them
  for `Snapshot.from_reports/2` to canonicalize.

  ## Why subprocesses

  Each project needs `Code.prepend_path/1` to add its compiled `ebin`
  directories to the code path so Argus can resolve module atoms.
  That modifies global VM state, so running more than one project in
  the same VM would race. The harness historically solved this by
  spawning per-project `elixir` subprocesses; this module preserves
  that behavior as a reusable library function.

  ## Ebin path discovery

  The harness script used compile-time `Path.wildcard("_build/dev/lib/*/ebin")`
  to enumerate argus's own compiled paths. Inside the argus app itself
  we can't do that — the compile-time value would be wherever argus
  was built, not where the user runs it. Instead, `Measure` calls
  `:code.get_path/0` at runtime to get whatever paths the current VM
  has loaded, filters out noise (kernel/stdlib/etc.), and passes them
  as `-pa` flags. This works across environments (dev/test/prod) and
  across installs (path dep / hex / vendored).
  """

  alias Argus.Autoresearch.{Config, Snapshot}

  @type project_result ::
          {:ok, map()}
          | {:error, term()}
          | {:missing, String.t()}

  @type per_project :: [{String.t(), project_result()}]

  @doc """
  Runs the coverage analysis against a list of projects. Returns a
  list of `{project_name, result}` tuples in the same order as the
  input.

  `projects` is a list of `{name, path_or_nil}` tuples (as produced
  by `Argus.Autoresearch.Config.resolve_tier/2`). Nil paths become
  `{:missing, name}` results without invoking a subprocess.

  Options:
  - `:analyses` — list of analyses to run (default: `["coverage"]`)
  - `:concurrency` — max parallel subprocesses (default: 4)
  - `:timeout_s` — per-project timeout in seconds (default: 300)
  - `:output_dir` — where to stash per-project results.json files
    (default: `.autoresearch/current/raw`). Each project gets a
    subdirectory by name.
  - `:on_progress` — optional 2-arity callback invoked as
    `on_progress.(project_name, result)` as each project finishes
  """
  @spec run_corpus([{String.t(), Path.t() | nil}], keyword()) :: per_project()
  def run_corpus(projects, opts \\ []) do
    analyses = Keyword.get(opts, :analyses, ["coverage"])
    concurrency = Keyword.get(opts, :concurrency, 4)
    timeout_s = Keyword.get(opts, :timeout_s, 300)
    output_dir = Keyword.get(opts, :output_dir, ".autoresearch/current/raw")
    on_progress = Keyword.get(opts, :on_progress, fn _, _ -> :ok end)

    File.mkdir_p!(output_dir)

    ebin_dirs = discover_ebin_dirs()
    script_path = analyze_project_script_path()

    projects
    |> Task.async_stream(
      fn project -> run_one(project, analyses, output_dir, script_path, ebin_dirs, timeout_s) end,
      max_concurrency: concurrency,
      timeout: (timeout_s + 30) * 1_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(projects)
    |> Enum.map(fn
      {{:ok, result}, {name, _}} ->
        on_progress.(name, result)
        {name, result}

      {{:exit, :timeout}, {name, _}} ->
        result = {:error, :measure_timeout}
        on_progress.(name, result)
        {name, result}
    end)
  end

  @doc """
  Convenience wrapper: load config, resolve a tier, run the corpus,
  and return a `%Snapshot{}` along with the per-project results for
  the caller to write to disk.

  Returns `{:ok, snapshot, per_project}` or `{:error, reason}`.
  """
  @spec measure_tier(Config.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t(), per_project()} | {:error, term()}
  def measure_tier(%Config{} = config, tier, opts \\ []) do
    with {:ok, projects} <- Config.resolve_tier(config, tier) do
      results =
        run_corpus(projects,
          concurrency: config.measure_concurrency,
          timeout_s: config.measure_timeout_s,
          output_dir: Keyword.get(opts, :output_dir, ".autoresearch/current/raw"),
          on_progress: Keyword.get(opts, :on_progress, fn _, _ -> :ok end)
        )

      successful_reports =
        results
        |> Enum.flat_map(fn
          {name, {:ok, report}} -> [{name, report}]
          _ -> []
        end)

      snapshot =
        Snapshot.from_reports(successful_reports,
          tier: tier,
          argus_git_sha: Keyword.get(opts, :argus_git_sha)
        )

      {:ok, snapshot, results}
    end
  end

  # ── Per-project execution ────────────────────────────────────────────

  defp run_one({name, nil}, _analyses, _output_dir, _script, _ebins, _timeout_s) do
    {:missing, name}
  end

  defp run_one({name, path}, analyses, output_dir, script, ebin_dirs, timeout_s) do
    project_dir = Path.join(output_dir, name)
    File.mkdir_p!(project_dir)

    results_path = Path.join(project_dir, "results.json")
    error_log_path = Path.join(project_dir, "error.log")

    case run_analysis_subprocess(path, results_path, analyses,
           script: script,
           ebin_dirs: ebin_dirs,
           error_log_path: error_log_path,
           timeout_s: timeout_s
         ) do
      :ok ->
        read_report(results_path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Runs `scripts/analyze_project.exs` in a child `elixir` subprocess
  against a single project. This is the load-bearing primitive both
  `run_corpus/2` and `scripts/harness.exs` use.

  Using `elixir` directly (rather than `mix run`) sidesteps the Mix
  build lock so multiple invocations can run in parallel. The child
  VM gets argus's compiled `ebin` directories via `-pa` flags so it
  can load the analyzer without a Mix project.

  Options:
  - `:script` — path to `analyze_project.exs` (default: resolved
    relative to current working directory)
  - `:ebin_dirs` — list of ebin directories to pass as `-pa` flags
    (default: auto-discovered via `discover_ebin_dirs/0`)
  - `:error_log_path` — path to write subprocess stderr+stdout
    (default: `error.log` next to `results_path`)
  - `:timeout_s` — subprocess timeout in seconds (currently ignored;
    the parent enforces it via `Task.async_stream`)
  """
  @spec run_analysis_subprocess(Path.t(), Path.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def run_analysis_subprocess(project_path, results_path, analyses, opts \\ []) do
    script = Keyword.get_lazy(opts, :script, &analyze_project_script_path/0)
    ebin_dirs = Keyword.get_lazy(opts, :ebin_dirs, &discover_ebin_dirs/0)

    error_log_path =
      Keyword.get_lazy(opts, :error_log_path, fn ->
        Path.join(Path.dirname(results_path), "error.log")
      end)

    pa_flags = Enum.flat_map(ebin_dirs, fn dir -> ["-pa", dir] end)
    script_args = [project_path, "--json", results_path | analyses]

    boot_code =
      "Application.load(:argus); System.argv(#{inspect(script_args)}); Code.require_file(#{inspect(script)})"

    args = pa_flags ++ ["-e", boot_code]

    File.mkdir_p!(Path.dirname(error_log_path))
    File.write!(error_log_path, "")
    log = File.stream!(error_log_path, [:append])

    case System.cmd("elixir", args, stderr_to_stdout: true, into: log) do
      {_, 0} ->
        if File.exists?(results_path),
          do: :ok,
          else: {:error, {:no_output, error_log_path}}

      {_, code} ->
        {:error, {:exit_code, code, error_log_path}}
    end
  end

  defp read_report(results_path) do
    case File.read(results_path) do
      {:ok, content} ->
        try do
          {:ok, :json.decode(content)}
        rescue
          e -> {:error, {:decode_failed, Exception.message(e)}}
        end

      {:error, reason} ->
        {:error, {:read_failed, reason}}
    end
  end

  # ── Ebin discovery ───────────────────────────────────────────────────

  # Return the list of ebin directories needed to boot a subprocess VM
  # that can run argus. Filters :code.get_path/0 down to app-specific
  # ebins under _build/, excluding stdlib/kernel/etc. which the child
  # VM will load automatically.
  @doc false
  @spec discover_ebin_dirs() :: [String.t()]
  def discover_ebin_dirs do
    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.filter(&String.contains?(&1, "_build"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The analyze_project script lives in `scripts/analyze_project.exs`
  # at the argus repo root. When invoked via a Mix task, `File.cwd!/0`
  # is the repo root (Mix sets it before running the task), so this
  # resolves correctly. If argus is ever installed as a Hex dep with
  # compiled escripts, this assumption breaks — but Hex-based autoresearch
  # isn't a supported workflow today.
  defp analyze_project_script_path do
    Path.expand("scripts/analyze_project.exs")
  end
end
