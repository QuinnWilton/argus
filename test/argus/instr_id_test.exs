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

  test "a function named nil keeps its name (gleam@dynamic:nil/0)" do
    id = InstrId.mint(InstrId.func_id(:gleam@dynamic, nil, 0), 5)
    assert id == ":gleam@dynamic:nil/0#5"

    assert InstrId.parse(id) ==
             {:ok, %InstrId{module: ":gleam@dynamic", func: "nil", arity: 0, idx: 5}}
  end

  test "a function name holding the separators, or none at all, round-trips" do
    for {module, name} <- [
          {:lists, :"a:b"},
          {:lists, :"weird#1"},
          {:lists, :"f/2#3"},
          {:lists, :""},
          {:"my:mod", :run},
          {:"my\"mod", :"x:y"},
          {Demo, :"::"}
        ] do
      id = InstrId.mint(InstrId.func_id(module, name, 2), 7)
      assert {:ok, parsed} = InstrId.parse(id)

      assert {parsed.module, parsed.func, parsed.arity, parsed.idx} ==
               {inspect(module), Atom.to_string(name), 2, 7}
    end
  end

  property "any module and function atom round-trip through an ID" do
    atom = map(string(:printable, max_length: 12), &String.to_atom/1)

    check all(
            module <- one_of([atom, member_of([Demo, Demo.Sub, :lists, nil, :gleam@dynamic])]),
            name <- one_of([atom, member_of([nil, true, :"-f/1-fun-0-", :""])]),
            arity <- integer(0..255),
            idx <- integer(0..10_000)
          ) do
      id = InstrId.mint(InstrId.func_id(module, name, arity), idx)
      assert {:ok, parsed} = InstrId.parse(id)

      assert parsed == %InstrId{
               module: inspect(module),
               func: Atom.to_string(name),
               arity: arity,
               idx: idx
             }

      assert InstrId.format(parsed) == id
    end
  end

  property "parse is the inverse of format, including pathological names" do
    name_chars = [?a..?z, ?A..?Z, ?0..?9, ?_, ?-, ?.]

    # Function names may embed the separator characters themselves (quoted
    # atoms, generated closure names).
    func_gen =
      gen all(
            base <- string(name_chars, min_length: 1),
            infix <- member_of(["", "/", "#", ":", "/2-fun-0-"])
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
