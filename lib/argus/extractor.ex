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

  Pass extractors via the `:extractors` option to `Argus.Pipeline.run/3`
  or `Argus.analyze/3`.
  """

  @type module_data :: %{
          module: atom(),
          exports: list(),
          attributes: keyword(),
          compile_info: keyword(),
          functions: list()
        }

  @callback extract(module_data()) :: Argus.Pipeline.Emit.facts()
end
