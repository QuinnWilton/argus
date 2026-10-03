defmodule Argus.Pipeline.BaseTest do
  @moduledoc """
  A module's base kept (`Argus.Pipeline.Base`) reads back as the
  pipeline computed it, and the pipeline runs extractors over kept bases
  as over computed ones — computing afresh a base it has none of, or
  cannot read.
  """
  use ExUnit.Case, async: true

  alias Argus.Instr.Reaching
  alias Argus.Pipeline
  alias Argus.Pipeline.{Base, Disassemble, Emit}

  @modules [
    Argus.Test.Fixtures.EtsBounded,
    Argus.Test.Fixtures.PidFlow.ConnSup,
    Argus.Test.Fixtures.Specs,
    :gen_server,
    Enum
  ]

  defp path(mod), do: to_string(:code.which(mod))

  # What the pipeline computes of a module before its extractors run.
  defp computed(path) do
    {:ok, data} = Disassemble.disassemble_path(path)

    typed =
      data.module
      |> Emit.emit_module(
        data.exports,
        data.imports,
        data.attributes,
        data.functions,
        data.line_table
      )
      |> Map.take(Pipeline.typed_relations())
      |> Argus.Facts.decode()

    cfg = Argus.Cfg.build(typed)
    reaching = Reaching.uses(data.module, data.functions)
    {data, typed, cfg, reaching}
  end

  test "a kept base reads back as it was computed, in another process" do
    for mod <- @modules do
      path = path(mod)

      {kept, fresh} =
        Task.await(
          Task.async(fn ->
            {data, typed, cfg, reaching} = computed(path)
            {Base.keep(data, typed, cfg, reaching), {data, typed, cfg, reaching}}
          end)
        )

      restored = Task.await(Task.async(fn -> Base.restore(kept, path) end))
      {data, typed, cfg, reaching} = fresh

      assert restored.data == data, "#{inspect(mod)}: the disassembly"
      assert restored.typed == {:ok, typed}, "#{inspect(mod)}: the decoded facts"
      assert restored.cfg == cfg, "#{inspect(mod)}: the control-flow graphs"
      assert restored.reaching == reaching, "#{inspect(mod)}: the reaching definitions"
      assert Base.restore(kept, path, typed: false).typed == :not_read
    end
  end

  test "a base whose steps failed keeps their nil" do
    {data, _typed, _cfg, _reaching} = computed(path(:gen_server))
    kept = Base.keep(data, nil, %{}, nil)

    for typed? <- [true, false] do
      assert %{cfg: %{}, reaching: nil, typed: {:ok, nil}} =
               Base.restore(kept, "elsewhere.beam", typed: typed?)
    end

    assert Base.restore(kept, "elsewhere.beam").data.beam == "elsewhere.beam"
  end

  test "extractors over a kept base give what they give over a computed one; a base unreadable is computed" do
    extractors = [Argus.Extractors.CallArgs, Argus.Extractors.ETS, Argus.Extractors.TermFlow]

    for mod <- @modules do
      {:ok, fresh} = Pipeline.extract_module(path(mod), producers: extractors, keep_base: true)
      assert is_binary(fresh.base)

      for base <- [fresh.base, "not a base", nil] do
        {:ok, over} = Pipeline.extract_module(path(mod), producers: extractors, base: base)
        assert over.facts == fresh.facts, "#{inspect(mod)} over #{inspect(base, limit: 3)}"
      end
    end
  end

  test "the base's own rows are the emitter's, whatever base is handed in" do
    for mod <- @modules do
      {:ok, fresh} = Pipeline.extract_module(path(mod), producers: [:base], keep_base: true)
      {:ok, handed} = Pipeline.extract_module(path(mod), producers: [:base], base: fresh.base)
      assert handed.facts == fresh.facts
      assert handed.base == nil
    end
  end
end
