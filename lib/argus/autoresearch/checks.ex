defmodule Argus.Autoresearch.Checks do
  @moduledoc """
  Runs the pre-accept barrier for the autoresearch loop.

  Two layers of protection:

  1. **Checks barrier** — a list of shell commands from
     `Config.checks_barrier`. Runs them sequentially; the first
     failure aborts the barrier and blocks `accept`. Default:
     `mix format --check-formatted`, `mix compile --warnings-as-errors`,
     `mix test`, `mix dialyzer`.

  2. **Canary correctness cross-check** — a semantic regression guard
     that runs the default correctness analyses against a single
     canary project and compares finding counts to a committed
     fixture. Catches extractor changes that drift correctness
     analysis outputs without breaking any test.

  `run/2` executes both layers and returns `:ok` or
  `{:error, {:barrier, failure}}` / `{:error, {:canary_drift, diff}}`.
  """

  alias Argus.Autoresearch.{Baseline, Config, Measure}

  # Correctness analyses used for the canary cross-check. Kept in sync
  # with scripts/analyze_project.exs's @correctness_analyses list so
  # the fixture matches what `mix argus` would show.
  @canary_analyses ~w(
    atom_safety
    call_cycle
    deferred_startup_deadlock
    distributed
    error_handling
    ets
    gen_statem
    one_for_one_coupling
    process_bottleneck
    process_registry
    supervision
    sync_call_in_init
    timeout_chain
    unlinked_spawn
    unsafe_task
  )

  @type failure ::
          {:command_failed, [String.t()], non_neg_integer(), String.t()}
          | {:canary_drift, map()}

  @type result :: :ok | {:error, failure()}

  @doc """
  Runs the checks barrier and (if baseline exists) the canary
  cross-check.

  Options:
  - `:config` — a `%Config{}` (default: loaded from
    `.autoresearch/config.exs`)
  - `:skip_canary` — skip the canary cross-check even if a baseline
    exists (useful for dry runs and tests)
  - `:baseline_dir` — override the baseline directory
  - `:on_step` — callback invoked as `on_step.(step_atom, :start | {:done, result})`
    so the Mix task can stream progress
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    on_step = Keyword.get(opts, :on_step, fn _step, _status -> :ok end)

    with {:ok, config} <- load_config(opts),
         :ok <- run_barrier(config.checks_barrier, on_step),
         :ok <- maybe_run_canary(config, opts, on_step) do
      :ok
    end
  end

  @doc """
  Runs the checks barrier only (no canary).
  """
  @spec run_barrier([[String.t() | [String.t()]]], (atom(), term() -> any())) :: result()
  def run_barrier(commands, on_step \\ fn _, _ -> :ok end) do
    Enum.reduce_while(commands, :ok, fn [cmd, args], :ok ->
      on_step.({:command, [cmd | args]}, :start)

      case run_command(cmd, args) do
        {:ok, _output} ->
          on_step.({:command, [cmd | args]}, {:done, :ok})
          {:cont, :ok}

        {:error, {exit_code, output}} ->
          failure = {:command_failed, [cmd | args], exit_code, tail(output, 40)}
          on_step.({:command, [cmd | args]}, {:done, {:error, failure}})
          {:halt, {:error, failure}}
      end
    end)
  end

  @doc """
  Runs the canary correctness cross-check against the canary project
  defined in the config. Returns `:ok` if current finding counts
  match the committed fixture, or `{:error, {:canary_drift, diff_map}}`
  where `diff_map` shows which analyses drifted.

  `{:error, :no_canary}` means there's no committed fixture yet —
  typically the first run before `init`. The caller decides whether
  to treat this as a pass.
  """
  @spec run_canary(Config.t(), keyword()) :: :ok | {:error, term()}
  def run_canary(%Config{} = config, opts \\ []) do
    baseline_dir = Keyword.get(opts, :baseline_dir, Baseline.default_dir())
    output_dir = Keyword.get(opts, :output_dir, ".autoresearch/current/canary")
    timeout_s = Keyword.get(opts, :timeout_s, 120)

    with canary_name when is_binary(canary_name) <- config.canary_project || :no_canary_configured,
         {:ok, fixture} <- Baseline.read_canary(baseline_dir),
         {:ok, path} <- resolve_canary_path(config, canary_name),
         {:ok, counts} <- measure_canary(canary_name, path, output_dir, timeout_s) do
      case compare_canary(fixture, counts) do
        :ok -> :ok
        {:drift, diff} -> {:error, {:canary_drift, diff}}
      end
    else
      :no_canary_configured -> {:error, :no_canary_configured}
      other -> other
    end
  end

  @doc """
  Captures the canary project's current finding counts, ready to be
  written to `canary_correctness.json`. Used during initial baseline
  setup.
  """
  @spec capture_canary_fixture(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture_canary_fixture(%Config{} = config, opts \\ []) do
    output_dir = Keyword.get(opts, :output_dir, ".autoresearch/current/canary")
    timeout_s = Keyword.get(opts, :timeout_s, 120)

    with canary_name when is_binary(canary_name) <- config.canary_project || :no_canary_configured,
         {:ok, path} <- resolve_canary_path(config, canary_name) do
      measure_canary(canary_name, path, output_dir, timeout_s)
    else
      :no_canary_configured -> {:error, :no_canary_configured}
      other -> other
    end
  end

  # ── Internals ────────────────────────────────────────────────────────

  defp load_config(opts) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} -> {:ok, config}
      :error -> Config.load()
    end
  end

  defp maybe_run_canary(config, opts, on_step) do
    if Keyword.get(opts, :skip_canary, false) do
      :ok
    else
      on_step.(:canary, :start)

      case run_canary(config, opts) do
        :ok ->
          on_step.(:canary, {:done, :ok})
          :ok

        # No committed canary fixture yet — treat as pass. Loop can
        # call capture_canary_fixture during the initial baseline.
        {:error, :no_canary} ->
          on_step.(:canary, {:done, :skipped})
          :ok

        {:error, :no_canary_configured} ->
          on_step.(:canary, {:done, :skipped})
          :ok

        # Project missing on this machine — same rationale as above.
        {:error, {:project_missing, _}} ->
          on_step.(:canary, {:done, :skipped})
          :ok

        {:error, reason} = err ->
          on_step.(:canary, {:done, err})
          {:error, reason}
      end
    end
  end

  defp run_command(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {code, output}}
    end
  rescue
    e in ErlangError ->
      {:error, {127, "failed to execute #{cmd}: #{Exception.message(e)}"}}
  end

  defp resolve_canary_path(%Config{} = config, canary_name) do
    path = Path.join(config.corpus_root, canary_name)

    if File.dir?(path) do
      {:ok, path}
    else
      {:error, {:project_missing, canary_name}}
    end
  end

  defp measure_canary(canary_name, path, output_dir, timeout_s) do
    File.mkdir_p!(output_dir)

    case Measure.run_corpus(
           [{canary_name, path}],
           analyses: @canary_analyses,
           concurrency: 1,
           timeout_s: timeout_s,
           output_dir: output_dir
         ) do
      [{^canary_name, {:ok, report}}] ->
        {:ok, counts_from_report(report)}

      [{^canary_name, {:error, reason}}] ->
        {:error, {:canary_measure_failed, reason}}

      [{^canary_name, {:missing, _}}] ->
        {:error, {:project_missing, canary_name}}
    end
  end

  # Reduce a full per-project report to a flat map of
  # analysis_name => finding_count for comparison.
  defp counts_from_report(%{"analyses" => analyses}) when is_map(analyses) do
    Map.new(analyses, fn {name, entry} ->
      {name, Map.get(entry, "finding_count", 0)}
    end)
  end

  defp counts_from_report(_), do: %{}

  # Compare baseline fixture to fresh counts. Returns :ok if they
  # match, or {:drift, diff_map} where diff_map describes the
  # analyses that differ.
  defp compare_canary(fixture, counts) do
    all_analyses =
      Map.keys(fixture) |> Enum.concat(Map.keys(counts)) |> Enum.uniq() |> Enum.sort()

    drift =
      Enum.reduce(all_analyses, %{}, fn analysis, acc ->
        base = Map.get(fixture, analysis, 0)
        curr = Map.get(counts, analysis, 0)

        if base != curr do
          Map.put(acc, analysis, %{baseline: base, current: curr, delta: curr - base})
        else
          acc
        end
      end)

    if drift == %{}, do: :ok, else: {:drift, drift}
  end

  # Keep only the last N lines of output so failure logs stay
  # readable in the event log.
  defp tail(output, n) do
    output
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end
end
