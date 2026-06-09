defmodule Argus.InstrIdTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.InstrId

  doctest Argus.InstrId

  test "parses ids with generated fun names containing / # and -" do
    assert {:ok, id} = InstrId.parse("Elixir.Grid:-points/2-fun-0-/3#5")
    assert id.module == "Elixir.Grid"
    assert id.func == "-points/2-fun-0-"
    assert id.arity == 3
    assert id.idx == 5
  end

  test "parses erlang-style module names" do
    assert {:ok, id} = InstrId.parse(":lists:reverse/1#0")
    assert id.module == ":lists"
    assert id.func == "reverse"
  end

  test "rejects shapes that are not instruction ids" do
    assert InstrId.parse("") == :error
    assert InstrId.parse("no separators") == :error
    assert InstrId.parse("Mod:func/1") == :error
    assert InstrId.parse("Mod:func#3") == :error
    assert InstrId.parse("Mod:func/x#3") == :error
    assert InstrId.parse("Mod:func/1#") == :error
    assert InstrId.parse(":func/1#0") == :error
  end

  property "parse is the inverse of format, including pathological names" do
    name_chars = [?a..?z, ?A..?Z, ?0..?9, ?_, ?-, ?.]

    # Function names may embed the separator characters themselves (quoted
    # atoms, generated closure names) — parsing must stay right-anchored.
    func_gen =
      gen all(
            base <- string(name_chars, min_length: 1),
            infix <- member_of(["", "/", "#", "/2-fun-0-"])
          ) do
        base <> infix <> "x"
      end

    check all(
            module <- string(name_chars, min_length: 1),
            func <- func_gen,
            arity <- integer(0..255),
            idx <- integer(0..10_000)
          ) do
      id = %InstrId{module: module, func: func, arity: arity, idx: idx}
      assert InstrId.parse(InstrId.format(id)) == {:ok, id}
      assert InstrId.fa(id) == {func, arity}
    end
  end
end
