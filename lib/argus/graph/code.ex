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

  alias Argus.Graph.Extraction
  alias Argus.Graph.Reads

  use Roux.Query, code: [exclude: &Reads.schema_module?/1]

  @doc false
  # Every module whose code these queries digest: the analyses, and the
  # extractors their `extractors/0` name.
  @spec roots() :: [module()]
  def roots, do: Argus.Analysis.builtin_analysis_modules() ++ Extraction.extractors()

  @doc """
  The roots of a producer's code: `Argus.Pipeline` for the base, and
  the extractor besides for an extractor, which it reaches only by
  dynamic dispatch (`extractor.extract/1`). Every extractor reads what
  the base computes, so the base's code is in every producer's.
  """
  @spec producer_roots(Argus.Pipeline.producer()) :: [module()]
  def producer_roots(:base), do: [Argus.Pipeline]
  def producer_roots(extractor) when is_atom(extractor), do: [Argus.Pipeline, extractor]

  @doc """
  The modules a producer's rows depend on, each with the file its
  object code was read from (`Roux.Code.closure/2` of
  `producer_roots/1`): the schema's modules are left out, and walked
  through, as `producer_code` digests them. An edit to one extractor
  moves its own closure's digest and no other producer's.
  """
  @spec closure(Argus.Pipeline.producer()) ::
          {:ok, [{module(), Roux.Code.location()}]} | {:error, {:no_beam, module()}}
  def closure(producer),
    do: Roux.Code.closure(producer_roots(producer), exclude: &Reads.schema_module?/1)

  @doc """
  Whether a producer can read specs from the code path
  (`Argus.Specs.installed/2`): its rows then depend on the specs it
  read (`installed_specs`, `Argus.Graph.Reads`) as well as on the
  module. A producer whose closure cannot be read may.
  """
  @spec reads_installed?(Argus.Pipeline.producer()) :: boolean()
  def reads_installed?(producer) do
    case closure(producer) do
      {:ok, modules} -> List.keymember?(modules, Argus.Specs, 0)
      {:error, _} -> true
    end
  end

  defquery :producer_code, key: :all, code: {__MODULE__, :roots, []} do
    for producer <- Extraction.producers(), into: %{} do
      {producer, digest(producer_roots(producer), db)}
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
    case Roux.Code.digest(roots, exclude: &Reads.schema_module?/1, store: db.blob) do
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
