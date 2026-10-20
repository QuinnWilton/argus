defmodule Argus.Stages do
  @moduledoc """
  How the points-to stage is solved, whoever solves it: the full
  program, the selective one in its place when the full fixpoint
  outgrows its budget, and the field-insensitive one when even the
  selective one does (`Argus.Analysis.Extraction.derive_points_to/2`
  says why). Which one runs is a function of the facts, never of time:
  each program counts its fixpoint's rows and writes `points_to_overflow`,
  the relations that reached the budget (`priv/dl/points_to.dl`), or its
  engine stops it as one of them grows past (`{:limitsize, ...}`), which
  reads as the same overflow.

  A facts directory's derivation (`Argus.Analysis.Extraction`) and the
  query graph (`Argus.Graph.Solve`, over the blob store) each solve the
  programs their own way and hand that to `points_to/5`, so the policy
  is written once.
  """

  require Logger

  @typedoc """
  Which program's outputs the stage has: the full one's, or the
  selective or field-insensitive one's with the hub objects its
  field-insensitive pass resolved (every object, for the
  field-insensitive one).
  """
  @type mode :: :full | {:selective, [String.t()]} | {:field_insensitive, [String.t()]}

  @typedoc """
  Solves a program over what the previous solve returned (the first
  time, what `points_to/5` was handed): `{:ok, results, solved}`, the
  program's outputs as rows by relation name (at least
  `points_to_overflow`, and `hub_object` for the selective and
  field-insensitive programs) and what the next solve goes on from, or
  `{:error, reason}`.
  """
  @type solve(acc) :: (Path.t(), acc ->
                         {:ok, %{String.t() => [[String.t()]]}, acc} | {:error, term()})

  @doc """
  The points-to stage: `{:ok, solved, mode}` with what the solve whose
  outputs are the stage's returned, or `{:error, reason, solved}` with
  what the last solve returned (or `acc`), for the caller to clean up
  after. A selective or field-insensitive run is reported with a
  warning naming the hub objects it resolved field-insensitively; a
  failure is the caller's to report (`failed/1`).
  """
  @spec points_to(solve(acc), acc, Path.t(), Path.t(), Path.t()) ::
          {:ok, acc, mode()} | {:error, term(), acc}
        when acc: var
  def points_to(solve, acc, full_path, selective_path, field_insensitive_path) do
    case attempt(solve, full_path, acc) do
      {:ok, solved, _results} ->
        {:ok, solved, :full}

      {:over, full_over, acc} ->
        case attempt(solve, selective_path, acc) do
          {:ok, solved, results} ->
            hubs = hub_objects(results)

            Logger.warning(
              "points-to: the full stage outgrew its budget (#{budget_summary(full_over)}); " <>
                "ran it selective, " <> hub_summary(hubs)
            )

            {:ok, solved, {:selective, hubs}}

          {:over, selective_over, acc} ->
            field_insensitive(solve, acc, field_insensitive_path, full_over, selective_over)

          {:error, reason, acc} ->
            {:error, reason, acc}
        end

      {:error, reason, acc} ->
        {:error, reason, acc}
    end
  end

  # The field-insensitive stage, when even the selective one outgrew
  # the budget: it resolves every object field-insensitively, so it
  # outgrows the budget only where the field-insensitive pass does, and
  # then the stage fails.
  defp field_insensitive(solve, acc, path, full_over, selective_over) do
    case attempt(solve, path, acc) do
      {:ok, solved, results} ->
        objects = hub_objects(results)

        Logger.warning(
          "points-to: the full stage outgrew its budget (#{budget_summary(full_over)}), " <>
            "and so did the selective one (#{budget_summary(selective_over)}); " <>
            "ran it field-insensitive, resolving every object that way (#{length(objects)})"
        )

        {:ok, solved, {:field_insensitive, objects}}

      {:over, over, acc} ->
        {:error, {:over_budget, over}, acc}

      {:error, reason, acc} ->
        {:error, reason, acc}
    end
  end

  # One program's solve, over what the last one returned: `{:ok,
  # solved, results}` within the budget, `{:over, over, acc}` past it
  # with what to go on from, or `{:error, reason, acc}`. A program
  # writes every relation the one before it did, so each partial one
  # is replaced.
  defp attempt(solve, path, acc) do
    case solve.(path, acc) do
      {:ok, results, solved} ->
        case overflow(results) do
          {:ok, []} -> {:ok, solved, results}
          {:ok, over} -> {:over, over, solved}
          {:error, reason} -> {:error, reason, solved}
        end

      # The engine stopped the fixpoint as a relation grew past its
      # budget: the same overflow, met sooner.
      {:error, {:limitsize, relation, rows, limit}} ->
        {:over, [{relation, rows, limit}], acc}

      {:error, reason} ->
        {:error, reason, acc}
    end
  end

  defp hub_objects(results),
    do: results |> Map.get("hub_object", []) |> List.flatten() |> Enum.sort()

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
    do: "the stage outgrew its budget even field-insensitive (#{budget_summary(over)})"

  defp failure_summary(:flowlog_timeout),
    do: "the stage did not finish within the solve's timeout (:timeout)"

  defp failure_summary(reason), do: "the stage failed: " <> Argus.FlowLog.describe_error(reason)

  defp budget_summary(over) do
    Enum.map_join(over, ", ", fn {relation, rows, budget} ->
      "#{relation} reached #{rows} rows, over #{budget}"
    end)
  end

  defp hub_summary([]), do: "which found no hub object"

  defp hub_summary(hubs) do
    shown = Enum.take(hubs, 3)
    more = if length(hubs) > length(shown), do: ", …", else: ""

    "resolving #{length(hubs)} hub objects field-insensitively " <>
      "(#{Enum.join(shown, ", ")}#{more})"
  end
end
