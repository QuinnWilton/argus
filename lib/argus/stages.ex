defmodule Argus.Stages do
  @moduledoc """
  How the process points-to stage is solved, whoever solves it: the
  exact program, and the bounded one in its place when the exact
  fixpoint outgrows its budget (`Argus.Analysis.Extraction.derive_points_to/2`
  says why). Which one runs is a function of the facts, never of time:
  each program counts its fixpoint's rows once it is complete and writes
  `points_to_overflow`, the relations that reached the budget
  (`priv/dl/points_to.dl`).

  A facts directory's derivation (`Argus.Analysis.Extraction`) and the
  query graph (`Argus.Graph.Solve`, over the blob store) each solve the
  programs their own way and hand that to `points_to/4`, so the policy
  is written once.
  """

  require Logger

  @typedoc """
  Which program's outputs the stage has: the exact one's, or the
  bounded one's with the leaves its coarse pass resolved.
  """
  @type mode :: :exact | {:bounded, [String.t()]}

  @typedoc """
  Solves a program over what the previous solve returned (the first
  time, what `points_to/4` was handed): `{:ok, results, solved}`, the
  program's outputs as rows by relation name (at least
  `points_to_overflow`, and `pervasive` for the bounded program) and
  what the next solve goes on from, or `{:error, reason}`.
  """
  @type solve(acc) :: (Path.t(), acc ->
                         {:ok, %{String.t() => [[String.t()]]}, acc} | {:error, term()})

  @doc """
  The points-to stage: `{:ok, solved, mode}` with what the solve whose
  outputs are the stage's returned, or `{:error, reason, solved}` with
  what the last solve returned (or `acc`), for the caller to clean up
  after. A bounded run is reported with a warning naming the leaves it
  resolved coarsely; a failure is the caller's to report
  (`failed/1`).
  """
  @spec points_to(solve(acc), acc, Path.t(), Path.t()) ::
          {:ok, acc, mode()} | {:error, term(), acc}
        when acc: var
  def points_to(solve, acc, exact_path, bounded_path) do
    case solve.(exact_path, acc) do
      {:ok, results, solved} ->
        case overflow(results) do
          {:ok, []} -> {:ok, solved, :exact}
          {:ok, exact_over} -> bounded(solve, solved, bounded_path, exact_over)
          {:error, reason} -> {:error, reason, solved}
        end

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  # The bounded stage over the facts the exact one was solved over: it
  # writes every relation the exact one does, so each partial one is
  # replaced.
  defp bounded(solve, acc, bounded_path, exact_over) do
    case solve.(bounded_path, acc) do
      {:ok, results, solved} ->
        case overflow(results) do
          {:ok, []} ->
            leaves = results |> Map.get("pervasive", []) |> List.flatten() |> Enum.sort()
            report_bounded(exact_over, leaves)
            {:ok, solved, {:bounded, leaves}}

          {:ok, over} ->
            {:error, {:over_budget, over}, solved}

          {:error, reason} ->
            {:error, reason, solved}
        end

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  @doc """
  The relations that reached the stage's budget, `{relation, rows,
  budget}`: none when the fixpoint is complete. Every stage program
  writes `points_to_overflow`, so a solve without it is not one of the
  stage's.
  """
  @spec overflow(%{String.t() => [[String.t()]]}) ::
          {:ok, [{String.t(), integer(), integer()}]} | {:error, term()}
  def overflow(results) do
    case Map.fetch(results, "points_to_overflow") do
      {:ok, rows} ->
        {:ok,
         for [relation, count, budget] <- rows do
           {relation, String.to_integer(count), String.to_integer(budget)}
         end}

      :error ->
        {:error, {:missing_output, "points_to_overflow"}}
    end
  end

  defp report_bounded(exact_over, leaves) do
    Logger.warning(
      "points-to: the exact stage outgrew its budget (#{budget_summary(exact_over)}); " <>
        "ran it bounded, " <> pervasive_summary(leaves)
    )
  end

  @doc """
  A failed stage degrades every analysis that reads it: said once here,
  whichever caller runs it. Returns `{:error, {:points_to, reason}}`.
  """
  @spec failed(term()) :: {:error, {:points_to, term()}}
  def failed(reason) do
    Logger.warning(
      "points-to: " <> failure_summary(reason) <> "; the analyses reading it degrade"
    )

    {:error, {:points_to, reason}}
  end

  defp failure_summary({:over_budget, over}),
    do: "the stage outgrew its budget even bounded (#{budget_summary(over)})"

  defp failure_summary(:flowlog_timeout),
    do: "the stage did not finish within the solve's timeout (:timeout)"

  defp failure_summary(reason), do: "the stage failed: " <> Argus.FlowLog.describe_error(reason)

  defp budget_summary(over) do
    Enum.map_join(over, ", ", fn {relation, rows, budget} ->
      "#{relation} reached #{rows} rows, over #{budget}"
    end)
  end

  defp pervasive_summary([]), do: "which found no leaf pervasive"

  defp pervasive_summary(leaves) do
    shown = Enum.take(leaves, 3)
    more = if length(leaves) > length(shown), do: ", …", else: ""

    "resolving #{length(leaves)} pervasive leaves coarsely (#{Enum.join(shown, ", ")}#{more})"
  end
end
