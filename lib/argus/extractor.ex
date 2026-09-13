defmodule Argus.Extractor do
  @moduledoc """
  Behaviour for domain-specific fact extractors.

  Extractors receive a module's disassembly data and produce additional
  fact tuples beyond what the generic emitter provides. They run per-module,
  in parallel alongside base emission.

  ## Implementing an extractor

      defmodule MyExtractor do
        @behaviour Argus.Extractor

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
  What `extract/1` receives: the disassembly, plus — when the pipeline is
  calling — the module's call-site index and per-function control-flow
  graphs, so extractors neither walk the instruction stream for calls nor
  build their own graphs. `Argus.Extractor.Helpers.each_remote_call/3`
  and `Helpers.cfg/3` fall back to building both when absent, which is
  what an extractor called on bare disassembly (its unit tests) gets.
  """
  @type module_data :: %{
          required(:module) => atom(),
          required(:exports) => list(),
          required(:attributes) => keyword(),
          required(:functions) => list(),
          optional(:imports) => list(),
          optional(:line_table) => map(),
          optional(:call_sites) => [Argus.Extractor.CallSites.site()],
          optional(:cfg) => %{{String.t(), arity()} => Argus.Cfg.Function.t()}
        }

  @doc """
  The relations `extract/1` can emit. `Argus.ExtractorRelationsTest`
  checks every one against the schema and against the rules: a relation
  no rule reads is a fact nobody asked for, and the six that had
  accumulated before this callback existed were the same story six
  times.
  """
  @callback relations() :: [atom()]

  @callback extract(module_data()) :: Argus.Pipeline.Emit.facts()
end
