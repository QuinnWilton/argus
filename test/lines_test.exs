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

  @tag :tmp_dir
  test "from_facts_dir/1 reads line_info.facts, and a directory without it raises", %{
    tmp_dir: dir
  } do
    File.write!(Path.join(dir, "line_info.facts"), "A:b/0#1\t3\nA:b/0#2\t4\n")

    lines = Lines.from_facts_dir(dir)
    assert Lines.resolve(lines, "A:b/0#2") == 4
    assert Lines.resolve(lines, "A:b/0") == 3

    missing = Path.join([dir, "nonexistent", "line_info.facts"])

    assert %Argus.MissingRelationError{relation: "line_info", path: ^missing, reason: :enoent} =
             catch_error(Lines.from_facts_dir(Path.join(dir, "nonexistent")))
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

  describe "declaration_line/1" do
    # The fixtures are compiled by Mix, with debug info; a module
    # Code.compile_string/2 compiles under `mix test` has none.
    test "each module of a multi-module file is declared on its own line" do
      file = Path.expand("fixtures/supervision_fixture.ex", __DIR__)

      declared =
        for {line, n} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            [_, name] <- [Regex.run(~r/^defmodule ([\w.]+) do/, line)],
            into: %{},
            do: {Module.concat([name]), n}

      assert map_size(declared) > 10

      for {mod, n} <- declared do
        assert Lines.declaration_line(to_string(:code.which(mod))) == n, inspect(mod)
      end
    end

    test "a nested module is declared on its own line, and bytes read as the path" do
      outer = to_string(:code.which(Argus.Test.Fixtures.CallbackReceive))
      inner = to_string(:code.which(Argus.Test.Fixtures.CallbackReceive.BlockingInCallback))

      assert Lines.declaration_line(outer) == 1
      assert Lines.declaration_line(inner) == 11
      assert Lines.declaration_line(File.read!(inner)) == 11
    end

    test "an Erlang module is declared on its -module attribute" do
      forms =
        erlang_forms(
          "%% A header comment.\n\n-module(argus_lines_decl).\n-export([f/0]).\nf() -> ok.\n"
        )

      {:ok, _mod, beam} = :compile.forms(forms, [:debug_info, :binary])

      assert Lines.declaration_line(beam) == 3
    end

    test "a beam without debug info does not say" do
      forms = erlang_forms("-module(argus_lines_bare).\n-export([f/0]).\nf() -> ok.\n")
      {:ok, _mod, beam} = :compile.forms(forms, [:binary])

      assert Lines.declaration_line(beam) == nil
      assert Lines.declaration_line("not a beam") == nil
    end
  end

  defp erlang_forms(text) do
    {:ok, tokens, _end} = :erl_scan.string(String.to_charlist(text))

    tokens
    |> Enum.chunk_while(
      [],
      fn
        {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
        token, acc -> {:cont, [token | acc]}
      end,
      fn acc -> {:cont, acc} end
    )
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn form_tokens ->
      {:ok, form} = :erl_parse.parse_form(form_tokens)
      form
    end)
  end
end
