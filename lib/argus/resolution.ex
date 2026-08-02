defmodule Argus.Resolution do
  @moduledoc """
  How much of a relation the extractors could actually resolve.

  Facts that name a target carry the literal `"dynamic"` when the extractor
  could not work out what it was — a `GenServer.call(pid, ...)` whose pid
  came from a supervisor, a Registry lookup or the caller's own state. That
  is honest, and it is invisible: the row is still there, the analysis still
  joins on it, and nothing downstream says how many of its inputs were
  placeholders.

  It matters most for negative results. On one 531-module project,
  `sync_call` resolved a callee for **2** of its rows, so the four analyses
  keyed on a resolved target — `timeout_chain`, `process_bottleneck`,
  `sync_call_in_init`, `call_cycle` — were reasoning from two edges. None of
  their findings are wrong; every one rests on a real resolved edge. But
  "no bottlenecks found" reads as a statement about the program when it is
  mostly a statement about what could be seen.

  Distinct from `Argus.Extractors.Helpers.track_dynamic/5`, which records
  the same thing far more precisely and only when imprecision tracing is
  switched on. This needs nothing switched on: it counts what is already in
  the fact map, so it can be reported beside findings from any run.
  """

  @placeholder "dynamic"

  @type stat :: %{total: non_neg_integer(), dynamic: non_neg_integer(), resolved_pct: float()}

  @doc """
  Per-relation resolution rates, worst first.

  A row counts as unresolved when any column is the literal `"dynamic"`,
  which is the placeholder every extractor uses. Relations with no
  placeholder at all are omitted — reporting 100% for the relations that
  never had a target to resolve would bury the ones that did.
  """
  @spec stats(map()) :: [{atom(), stat()}]
  def stats(facts) when is_map(facts) do
    facts
    |> Enum.map(fn {relation, rows} -> {relation, tally(rows)} end)
    |> Enum.reject(fn {_relation, stat} -> stat.dynamic == 0 end)
    |> Enum.sort_by(fn {_relation, stat} -> stat.resolved_pct end)
  end

  @doc """
  One line per relation that lost something, for printing beside findings.
  """
  @spec summary(map()) :: [String.t()]
  def summary(facts) do
    for {relation, s} <- stats(facts) do
      "#{relation}: #{s.total - s.dynamic}/#{s.total} resolved " <>
        "(#{:erlang.float_to_binary(s.resolved_pct, decimals: 1)}%)"
    end
  end

  defp tally(rows) when is_list(rows) do
    total = length(rows)
    dynamic = Enum.count(rows, &unresolved?/1)

    %{
      total: total,
      dynamic: dynamic,
      resolved_pct: if(total == 0, do: 100.0, else: (total - dynamic) * 100 / total)
    }
  end

  defp tally(_other), do: %{total: 0, dynamic: 0, resolved_pct: 100.0}

  defp unresolved?(row) when is_list(row), do: Enum.any?(row, &(&1 == @placeholder))
  defp unresolved?(_row), do: false
end
