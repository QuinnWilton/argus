defmodule Argus.Extractor do
  @moduledoc """
  Behaviour for domain-specific fact extractors.

  Extractors receive one module's disassembly and return rows grouped by
  relation. The pipeline shares indexes and decoded facts between extractors;
  modules are processed concurrently.

  ## Implementing an extractor

      defmodule MyExtractor do
        @behaviour Argus.Extractor

        @impl true
        def relations, do: [:my_relation]

        @impl true
        def extract(module_data) do
          # Analyze module_data and return fact tuples.
          %{my_relation: [["val1", "val2"]]}
        end
      end

  An analysis names its extractors in `extractors/0`; pass extra ones via
  the `:extractors` option to `Argus.Analysis.extract_facts/3`.
  """

  @typedoc """
  Disassembly and optional pipeline-provided indexes.

  Use `Argus.Extractor.Helpers` to access call sites, control-flow graphs,
  decoded facts, and debug info. These helpers reuse supplied data or build it
  when called on bare disassembly. Extractors needing decoded facts must be
  listed in `Argus.Pipeline.typed_readers/0`; their input relations belong in
  `Argus.Pipeline.typed_relations/0`.

  `installed_specs` caches `Argus.Specs.installed/2` for the run. The pipeline
  reads `debug_info` only for extractors registered as debug-info readers.
  """
  @type module_data :: %{
          required(:module) => atom(),
          required(:exports) => list(),
          required(:attributes) => keyword(),
          required(:functions) => list(),
          optional(:imports) => list(),
          optional(:beam) => String.t() | binary(),
          optional(:line_table) => map(),
          optional(:call_sites) => [Argus.Extractor.CallSites.site()],
          optional(:cfg) => %{{String.t(), arity()} => Argus.Cfg.Function.t()},
          optional(:typed) => Argus.Facts.t() | nil,
          optional(:reaching) => MapSet.t(Argus.Dataflow.reaching_use()) | nil,
          optional(:origins_index) => map(),
          optional(:installed_specs) => :ets.tid(),
          optional(:debug_info) => {:ok, tuple()} | :error
        }

  @doc """
  Relations `extract/1` can emit. Each must be declared in the schema and
  consumed by a rule; `Argus.ExtractorRelationsTest` checks this contract.
  """
  @callback relations() :: [atom()]

  @callback extract(module_data()) :: Argus.Pipeline.Emit.facts()
end
