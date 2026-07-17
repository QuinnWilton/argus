defmodule Argus.LinesTest do
  use ExUnit.Case, async: true

  alias Argus.InstrId
  alias Argus.Lines

  @facts %{
    line_info: [
      ["MyMod:go/1#2", "10"],
      ["MyMod:go/1#3", "10"],
      ["MyMod:go/1#5", "12"],
      ["Other.Mod:run/0#1", "7"]
    ]
  }

  describe "resolve/2" do
    setup do
      %{lines: Lines.from_facts(@facts)}
    end

    test "instruction IDs resolve to their exact line", %{lines: lines} do
      assert Lines.resolve(lines, "MyMod:go/1#5") == 12
    end

    test "function IDs resolve to the function's first line", %{lines: lines} do
      assert Lines.resolve(lines, "MyMod:go/1") == 10
    end

    test "an unstamped instruction falls back to its function", %{lines: lines} do
      # Index 0 carries no line (before the first marker) — still a
      # better answer than nothing.
      assert Lines.resolve(lines, "MyMod:go/1#0") == 10
    end

    test "InstrId structs and MFAs resolve too", %{lines: lines} do
      instr = %InstrId{module: "MyMod", func: "go", arity: 1, idx: 5}
      assert Lines.resolve(lines, instr) == 12
      assert Lines.resolve(lines, {Other.Mod, :run, 0}) == 7
    end

    test "non-ID strings resolve to nil, never a guess", %{lines: lines} do
      assert Lines.resolve(lines, "MyMod") == nil
      assert Lines.resolve(lines, "dynamic") == nil
      assert Lines.resolve(lines, "NoSuch:fn/9#1") == nil
    end
  end

  test "from_facts_dir/1 reads line_info.facts and misses read as empty" do
    dir = Path.join(System.tmp_dir!(), "argus_lines_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "line_info.facts"), "A:b/0#1\t3\nA:b/0#2\t4\n")

    lines = Lines.from_facts_dir(dir)
    assert Lines.resolve(lines, "A:b/0#2") == 4
    assert Lines.resolve(lines, "A:b/0") == 3

    empty = Lines.from_facts_dir(Path.join(dir, "nonexistent"))
    assert Lines.resolve(empty, "A:b/0#2") == nil
  after
    File.rm_rf(Path.join(System.tmp_dir!(), "argus_lines_test_*"))
  end

  test "resolution is end-to-end real against this project's bytecode" do
    {:ok, facts} = Argus.Pipeline.extract([Argus.Lines])
    lines = Lines.from_facts(facts)

    # Every remote call instruction in a module with a Line chunk
    # resolves to a positive line.
    call_ids =
      for [id, _func, _idx, op] <- facts[:instruction],
          op in ["call_ext", "call"],
          do: id

    assert call_ids != []
    assert Enum.all?(call_ids, fn id -> is_integer(Lines.resolve(lines, id)) end)
  end
end
