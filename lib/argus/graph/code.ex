defmodule Argus.Graph.Code do
  @moduledoc """
  The code the graph reaches by dynamic dispatch, as values: what makes
  an edit to one extractor re-run extraction alone, and an edit to one
  analysis's prose re-run that analysis's findings alone.

  A query's code version covers the code its module reaches through its
  import table (`Roux.Code`). The extractors and the analyses are
  reached another way — by name, through `Argus.Analysis.Catalog` and
  each analysis's `extractors/0` — and a version covering all of them
  would move every extraction and every solve at any edit to any of
  them. So they are values here, each versioned by all of that code and
  cheap to compute again:

    * `producer_code(:all)` — every producer extraction runs
      (`Argus.Graph.Extraction.producers/0`) and the digest of the code
      it runs (`Argus.Pipeline`, and the extractor itself), the schema's
      modules left out: `module_facts` reads it, and finds each
      producer's rows by that digest (`Argus.Graph.Pack`). An extractor
      edit moves its own digest; an edit to an analysis's prose moves
      none, and comes back the same.
    * `analysis_code(analysis)` — the module of a built-in analysis and
      the digest of its code: its program's files and its findings read
      it. An edit to one analysis moves only its own.
  """

  use Roux.Query, code: [exclude: &Argus.Graph.Reads.schema_module?/1]

  alias Argus.Graph.Extraction

  @doc false
  # Every module whose code these queries digest: the analyses, and the
  # extractors their `extractors/0` name.
  @spec roots() :: [module()]
  def roots, do: Argus.Analysis.builtin_analysis_modules() ++ Extraction.extractors()

  defquery :producer_code, key: :all, code: {__MODULE__, :roots, []} do
    for producer <- Extraction.producers(), into: %{} do
      roots = if producer == :base, do: [Argus.Pipeline], else: [Argus.Pipeline, producer]
      {producer, digest(roots, db)}
    end
  end

  defquery :analysis_code, key: analysis, code: {__MODULE__, :roots, []} do
    case Argus.Analysis.fetch_module(analysis) do
      {:ok, module} -> {module, digest([module], db)}
      :error -> :unknown
    end
  end

  # Code with no object code to read (compiled in memory) is named only
  # within the VM that loaded it: its digest never matches another VM's.
  defp digest(roots, db) do
    case Roux.Code.digest(roots, exclude: &Argus.Graph.Reads.schema_module?/1, store: db.blob) do
      {:ok, digest} -> digest
      {:error, reason} -> {:unversioned, reason, vm_token()}
    end
  end

  defp vm_token do
    key = {__MODULE__, :vm_token}

    case :persistent_term.get(key, nil) do
      nil ->
        token = :crypto.strong_rand_bytes(16)
        :persistent_term.put(key, token)
        token

      token ->
        token
    end
  end
end
