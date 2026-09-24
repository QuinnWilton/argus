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

  @moduletag :tmp_dir

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

  defp contents(dir) do
    for name <- dir |> File.ls!() |> Enum.sort(), into: %{} do
      {name, File.read!(Path.join(dir, name))}
    end
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

  test "extractors over kept bases write what they write over computed ones; a base missing or unreadable is computed",
       %{tmp_dir: tmp} do
    extractors = [Argus.Extractors.CallArgs, Argus.Extractors.ETS, Argus.Extractors.PidFlow]
    dirs = fn root -> Enum.map(extractors, &{&1, Path.join([tmp, root, inspect(&1)])}) end

    assert {:ok, %{bases: [first | rest]}} =
             Pipeline.run_shards(@modules, dirs.("fresh"), keep_bases: true)

    assert {:ok, _} = Pipeline.run_shards(@modules, dirs.("kept"), bases: [first | rest])

    assert {:ok, _} =
             Pipeline.run_shards(@modules, dirs.("mixed"), bases: [nil, "not a base" | tl(rest)])

    for {extractor, dir} <- dirs.("fresh") do
      [{^extractor, kept}] = Enum.filter(dirs.("kept"), &(elem(&1, 0) == extractor))
      [{^extractor, mixed}] = Enum.filter(dirs.("mixed"), &(elem(&1, 0) == extractor))
      assert contents(kept) == contents(dir), inspect(extractor)
      assert contents(mixed) == contents(dir), inspect(extractor)
    end
  end

  test "the base's own rows are the emitter's, whatever bases are handed in", %{tmp_dir: tmp} do
    fresh = [{:base, Path.join(tmp, "fresh")}]
    handed = [{:base, Path.join(tmp, "handed")}]
    assert {:ok, %{bases: bases}} = Pipeline.run_shards(@modules, fresh, keep_bases: true)
    assert {:ok, info} = Pipeline.run_shards(@modules, handed, bases: bases)
    refute Map.has_key?(info, :bases)
    assert contents(Path.join(tmp, "handed")) == contents(Path.join(tmp, "fresh"))
  end

  test "bases that are not one per module are refused", %{tmp_dir: tmp} do
    assert {:error, {:bases_mismatch, 5, 1}} =
             Pipeline.run_shards(@modules, [{Argus.Extractors.ETS, tmp}], bases: [nil])
  end
end
