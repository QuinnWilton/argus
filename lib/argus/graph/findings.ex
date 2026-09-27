defmodule Argus.Graph.Findings do
  @moduledoc """
  What an analysis found, line-free, and what extraction could not do.

    * `findings({program, analysis})` — the analysis's findings, built by
      argus from its solve's output rows (`Argus.Findings.Build`: each
      relation's rows deduplicated by its identity rule, evidence rows
      as related frames), and the rows a finding builder raised on;
      `{:error, reason}` when the solve failed. Anchors are modules,
      functions and instructions, never lines: an edit that only moves
      lines leaves them as they were, and nothing past them runs. Kept
      by digest (`store: :blob`): a warm run reads none it does not
      place. Versioned by every built-in analysis's code, whose prose
      and identity rules build them.
    * `extraction_errors(program)` — each module extraction could not
      read at all (`step: "module"`), and each step it recorded as
      failing on a module (the `extraction_error` relation: an extractor
      that raised, a module that outlived the per-module timeout).
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Findings.{Anchor, Build}
  alias Argus.Graph.{Relations, Solve}
  alias Roux.Runtime

  defquery :findings,
    key: {program, analysis},
    code: {Argus.Analysis, :builtin_analysis_modules, []},
    store: :blob,
    transient: &match?({:error, _}, &1),
    returns: {:ok, [Argus.Findings.finding()], [Build.failure()]} | {:error, term()} do
    with {:ok, results} <- results(db, program, analysis),
         {:ok, module} <- analysis_module(analysis) do
      {findings, failures} = Build.build(module, results)
      {:ok, findings, failures}
    end
  end

  @doc """
  An analysis's solved output rows, restricted to the relations it
  declares (`Argus.Analysis.filter_to_outputs/2`), by relation name:
  what `Argus.analyze/3` returns. Depends on the analysis's solve when
  called in a query.
  """
  @spec results(Roux.Database.t(), term(), Argus.Analysis.analysis()) ::
          {:ok, Argus.Analysis.result()} | {:error, term()}
  def results(db, program, analysis) do
    with {:ok, outputs} <- Runtime.query(db, :solve, {program, analysis}),
         {:ok, rows} <- Solve.read_outputs(db, outputs, :csv) do
      {:ok, Argus.Analysis.filter_to_outputs(rows, analysis)}
    end
  end

  defp analysis_module(analysis) do
    case Argus.Analysis.fetch_module(analysis) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:unknown_analysis, analysis}}
    end
  end

  defquery :extraction_errors, key: program do
    keys = Runtime.input(db, :program, program, default: [])

    whole =
      for key <- keys,
          {:error, reason} <- [Runtime.query(db, :module_semantic, key)] do
        %{module: nil, source: source(key), step: "module", reason: one_line(reason)}
      end

    steps =
      for [mod, step, reason] <- Relations.rows(db, program, :extraction_error) do
        %{module: Anchor.module_atom(mod), source: mod, step: step, reason: reason}
      end

    whole ++ steps
  end

  defp source({:data, _digest}), do: "(beam data)"
  defp source(path) when is_binary(path), do: path

  defp one_line(reason), do: reason |> inspect(limit: 20) |> String.replace(~r/\s+/, " ")
end
