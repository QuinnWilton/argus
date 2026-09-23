defmodule Argus.Pipeline.TypedRelationsTest do
  @moduledoc """
  The pipeline decodes only `Argus.Pipeline.typed_relations/0` for the
  passes that run in the VM. Every extractor, handed the module data the
  pipeline builds from those relations, emits exactly what it emits from
  every relation decoded: an extractor that starts reading another
  relation from `module_data.typed` fails here until the list names it.
  """
  use ExUnit.Case, async: true

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Pipeline
  alias Argus.Pipeline.{Disassemble, Emit}

  @modules [
    Argus.Test.Fixtures.ConditionalInitServer,
    Argus.Test.Fixtures.Quiet,
    Argus.Test.Fixtures.ParamFlow.Shapes,
    Argus.Test.Fixtures.ViaMidwife,
    Argus.Test.Fixtures.CatchShapes.Erpc,
    Logger.Formatter,
    GenServer
  ]

  test "the extractors read nothing from typed facts outside typed_relations/0" do
    extractors =
      Argus.Analysis.builtin_analysis_modules()
      |> Enum.flat_map(& &1.extractors())
      |> Enum.uniq()

    for module <- @modules do
      {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(module)))

      raw =
        Emit.emit_module(
          data.module,
          data.exports,
          data.imports,
          data.attributes,
          data.functions,
          data.line_table
        )

      full = module_data(data, Argus.Facts.decode(raw))

      subset =
        module_data(data, raw |> Map.take(Pipeline.typed_relations()) |> Argus.Facts.decode())

      for extractor <- extractors do
        assert extractor.extract(subset) == extractor.extract(full),
               "#{inspect(extractor)} reads a relation typed_relations/0 leaves out (#{inspect(module)})"
      end
    end
  end

  # What the pipeline attaches to a module's disassembly.
  defp module_data(data, typed) do
    reaching = Argus.Dataflow.reaching_uses(typed, params: true)

    Map.merge(data, %{
      call_sites: CallSites.index(data.module, data.functions),
      cfg: Argus.Cfg.build(typed),
      typed: typed,
      reaching: reaching,
      origins_index: Helpers.origins_index(%{reaching: reaching})
    })
  end
end
