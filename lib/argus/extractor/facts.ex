defmodule Argus.Extractor.Facts do
  @moduledoc """
  The rows an extractor emits: accumulating them into a relation map
  (`add_fact/3`), and recording where a value fell back to `"dynamic"`
  (`track_imprecision/5`, `track_dynamic/5`) when the coverage analysis
  asks for it.
  """

  alias Argus.Extractor.Helpers

  @doc """
  Prepend a row to the given relation in a facts map.
  """
  @spec add_fact(Argus.Pipeline.Emit.facts(), atom(), [String.t()]) :: Argus.Pipeline.Emit.facts()
  def add_fact(facts, relation, row) do
    Map.update(facts, relation, [row], &[row | &1])
  end

  # --- Coverage instrumentation ---
  #
  # Coverage tracing records unresolved values and skipped emissions. A
  # process-local flag keeps concurrent runs independent; disabled tracing
  # costs only a Process.get/2. The pipeline clears it in an after block.

  @tracing_key :argus_trace_imprecision

  @doc """
  Enable imprecision tracking for the current Erlang process. Subsequent
  `track_imprecision/5` and `track_dynamic/5` calls will record events.
  """
  @spec enable_tracing() :: :ok
  def enable_tracing do
    Process.put(@tracing_key, true)
    :ok
  end

  @doc """
  Disable imprecision tracking for the current Erlang process. Subsequent
  `track_*` calls become no-ops. Always called from the pipeline's
  `try/after` so the flag is cleared even on extractor errors.
  """
  @spec disable_tracing() :: :ok
  def disable_tracing do
    Process.delete(@tracing_key)
    :ok
  end

  @doc """
  Returns whether imprecision tracking is currently enabled for this process.
  Useful in tests; production code should just call the `track_*` helpers
  and rely on them to no-op when tracing is off.
  """
  @spec tracing_enabled?() :: boolean()
  def tracing_enabled? do
    Process.get(@tracing_key, false) == true
  end

  @doc """
  Record an imprecision event explicitly. Use directly when the extractor
  decided to skip a fact emission entirely (the "intentional skip" case
  is still information — the value was missing, not just dynamic).

  No-op unless tracing is enabled for the current process.
  """
  @spec track_imprecision(
          Argus.Pipeline.Emit.facts(),
          Helpers.instr_ctx(),
          atom(),
          atom(),
          atom() | String.t()
        ) :: Argus.Pipeline.Emit.facts()
  def track_imprecision(facts, ctx, category, relation, reason \\ :dynamic) do
    if tracing_enabled?() do
      add_fact(facts, :imprecision, [
        to_string(category),
        ctx.func_id,
        to_string(relation),
        to_string(reason)
      ])
    else
      facts
    end
  end

  @doc """
  Conditional wrapper around `track_imprecision/5`. When `value` indicates
  a dynamic fallback (the string `"dynamic"` or the atom `:dynamic`),
  records the event. No-op otherwise AND no-op when tracing is disabled.

  This is the right helper for wrapping an existing `resolve_callee` /
  `resolve_atom` call site — the wrapper is essentially free in the
  non-coverage case (a single `Process.get/2`).
  """
  @spec track_dynamic(
          Argus.Pipeline.Emit.facts(),
          term(),
          Helpers.instr_ctx(),
          atom(),
          atom()
        ) :: Argus.Pipeline.Emit.facts()
  def track_dynamic(facts, value, ctx, category, relation) do
    if tracing_enabled?() and dynamic_value?(value) do
      add_fact(facts, :imprecision, [
        to_string(category),
        ctx.func_id,
        to_string(relation),
        "dynamic"
      ])
    else
      facts
    end
  end

  # Arg-position results like `{:arg, 0}` are NOT dynamic — they carry
  # concrete information about which parameter the value came from.
  defp dynamic_value?("dynamic"), do: true
  defp dynamic_value?(:dynamic), do: true
  defp dynamic_value?({:arg, _}), do: false
  defp dynamic_value?(_), do: false
end
