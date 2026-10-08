defmodule Argus.Graph.Extraction do
  @moduledoc """
  The producers used by the extraction graph. Query entry points delegate to
  `Argus.Graph.FunctionPack`, which assembles cached function and producer facts.
  """

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

  @spec module_facts(Roux.Database.t(), term()) :: {:ok, Argus.Graph.Pack.t()} | {:error, term()}
  defdelegate module_facts(db, key), to: Argus.Graph.FunctionPack

  @spec module_semantic(Roux.Database.t(), term()) ::
          {:ok, %{atom() => binary()}} | {:error, term()}
  defdelegate module_semantic(db, key), to: Argus.Graph.FunctionPack
end
