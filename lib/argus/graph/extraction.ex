defmodule Argus.Graph.Extraction do
  @moduledoc """
  A module's facts, and the first cutoff seam.

    * `module_facts(beam_key)` — the module's rows from every producer
      (`Argus.Pipeline`'s base and every extractor an analysis runs:
      `producers/0`), one segment per producer in the blob store
      (`Argus.Graph.Pack`),
      with each relation's chunk digest; `{:error, reason}` for a beam
      the pipeline cannot read. Not kept in a manifest when the module
      was lost (it outlived the per-module timeout, or its worker
      exited), nor is anything that read it: the next run extracts it
      again.
    * `module_semantic(beam_key)` — the same digests without
      `line_info`: an edit that only moves lines extracts the module
      again, and this comes out equal, so nothing past it runs. No
      relation carries a module's attributes (`Argus.Pipeline.Emit`
      drops them), so the `vsn` checksum, which moves with every edit,
      reaches none.

  `module_facts` reads the code every producer runs as a value
  (`Argus.Graph.Code`'s `producer_code`): an extractor edit moves it,
  every module's facts run again, and each finds every other producer's
  rows by its trace and runs that extractor alone, over the module's
  kept base, writing its own segment. An edit to an
  analysis that names no other extractor moves nothing here.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Graph.{Frontend, Pack}
  alias Roux.Runtime

  @doc "Every producer the graph extracts: `:base` and `extractors/0`, in that order."
  @spec producers() :: [Argus.Pipeline.producer()]
  def producers, do: [:base | extractors()]

  @doc """
  The extractors the graph runs over every module: every built-in
  analysis's (coverage's too), the call-argument extractor every
  analysis reads through, and the resource extractors planchette's
  supervision tree reads. One extraction serves every solve.
  """
  @spec extractors() :: [module()]
  def extractors do
    analysis_extractors =
      Enum.flat_map(Argus.Analysis.builtin_analysis_modules(), & &1.extractors())

    ([Argus.Extractors.CallArgs, Argus.Extractors.ETS, Argus.Extractors.ApiCalls] ++
       analysis_extractors)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defquery :module_facts,
    key: beam_key,
    store: :blob,
    transient: &match?({:ok, %{lost: true}}, &1),
    returns: {:ok, Pack.t()} | {:error, term()} do
    case Runtime.query(db, :module_beam, beam_key) do
      {:ok, beam} ->
        module = Runtime.query(db, :module_name, beam_key)
        codes = Runtime.query(db, :producer_code, :all)
        Pack.extract(db, Frontend.read(beam), beam.hash, module, codes)

      :external ->
        {:error, {:external, beam_key}}
    end
  end

  defquery :module_semantic,
    key: beam_key,
    returns: {:ok, %{atom() => binary()}} | {:error, term()} do
    case Runtime.query(db, :module_facts, beam_key) do
      {:ok, %{relations: relations}} -> {:ok, Map.delete(relations, :line_info)}
      {:error, _} = error -> error
    end
  end
end
