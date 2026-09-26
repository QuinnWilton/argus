defmodule Scry.BeamTest do
  use ExUnit.Case, async: true

  alias Scry.Beam

  defp beam_of(module) do
    {^module, beam, _path} = :code.get_object_code(module)
    beam
  end

  defp with_chunk(beam, id, data) do
    {:ok, _mod, chunks} = :beam_lib.all_chunks(beam)
    {:ok, rebuilt} = :beam_lib.build_module(List.keystore(chunks, id, 0, {id, data}))
    rebuilt
  end

  test "beams differing only in ExCk or Docs are canonically equal" do
    beam = beam_of(Scry.Beam)
    refute :beam_lib.all_chunks(beam) |> elem(2) |> List.keyfind(~c"ExCk", 0) |> is_nil()

    tweaked =
      beam
      |> with_chunk(~c"ExCk", :erlang.term_to_binary(:different))
      |> with_chunk(~c"Docs", :erlang.term_to_binary(:different))

    refute tweaked == beam
    assert Beam.canonical(tweaked) == Beam.canonical(beam)
  end

  test "the canonical beam still disassembles and keeps its debug info" do
    canonical = Beam.canonical(beam_of(Scry.Beam))

    assert {:beam_file, Scry.Beam, _exports, _attrs, _info, _code} = :beam_disasm.file(canonical)

    assert {:ok, {Scry.Beam, [{:debug_info, {:debug_info_v1, _, _}}]}} =
             :beam_lib.chunks(canonical, [:debug_info])
  end

  test "code changes still change the canonical form" do
    beam = beam_of(Scry.Beam)
    other = beam_of(Scry.Scanner)
    refute Beam.canonical(beam) == Beam.canonical(other)
  end

  test "a non-beam binary passes through" do
    assert Beam.canonical("not a beam") == "not a beam"
  end
end
