defmodule Argus.TsvTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Souffle
  alias Argus.Tsv

  @moduletag :tmp_dir

  # Binaries drawn to hit the escaped characters often: a plain printable
  # string rarely holds a tab or a backslash, and never two in a row.
  defp field do
    one_of([
      string(:printable),
      binary(),
      [:printable |> string(max_length: 3), member_of(["\\", "\t", "\n", "\r", "\\t", "\\\\"])]
      |> one_of()
      |> list_of(max_length: 8)
      |> map(&Enum.join/1)
    ])
  end

  describe "escape/1 and unescape/1" do
    property "unescape undoes escape for every binary" do
      check all(value <- field()) do
        assert value |> Tsv.escape() |> Tsv.unescape() == value
      end
    end

    property "an escaped field holds no tab, newline or carriage return" do
      check all(value <- field()) do
        refute Tsv.escape(value) =~ ~r/[\t\n\r]/
      end
    end

    test "a field with nothing to escape is returned as it is" do
      value = "Elixir.Foo:bar/2#17"
      assert :erts_debug.same(Tsv.escape(value), value)
    end
  end

  describe "encode/1 and decode/1" do
    property "rows round-trip exactly, empty fields included" do
      check all(rows <- list_of(list_of(field(), min_length: 1, max_length: 5))) do
        assert rows |> Tsv.encode() |> IO.iodata_to_binary() |> Tsv.decode() == rows
      end
    end

    test "a row of one empty field survives" do
      assert [[""], ["a"], [""]] |> Tsv.encode() |> IO.iodata_to_binary() |> Tsv.decode() ==
               [[""], ["a"], [""]]
    end

    test "an empty file holds no rows" do
      assert Tsv.decode("") == []
    end
  end

  describe "through Souffle" do
    setup do
      unless Souffle.available?(), do: flunk("souffle not installed")
      :ok
    end

    property "a copied relation comes back as it was written", %{tmp_dir: tmp_dir} do
      rules = Path.join(tmp_dir, "copy.dl")

      File.write!(rules, """
      .decl r(a: symbol, b: symbol, c: symbol)
      .input r
      .decl o(a: symbol, b: symbol, c: symbol)
      .output o
      o(a, b, c) :- r(a, b, c).
      """)

      check all(
              rows <- list_of(list_of(field(), length: 3), min_length: 1, max_length: 6),
              max_runs: 15
            ) do
        facts_dir = Path.join(tmp_dir, "facts_#{System.unique_integer([:positive])}")
        File.mkdir_p!(facts_dir)
        File.write!(Path.join(facts_dir, "r.facts"), Tsv.encode(rows))

        assert {:ok, %{"o" => out}} = Souffle.run(facts_dir, rules)
        # Souffle has set semantics and its own order.
        assert Enum.sort(out) == rows |> Enum.uniq() |> Enum.sort()
      end
    end
  end

  describe "names no fact file could hold" do
    setup do
      unless Souffle.available?(), do: flunk("souffle not installed")
      :ok
    end

    # A function named with a tab used to write a six-column function_def
    # row, and Souffle refused the whole directory over it.
    test "reach Souffle and come back whole", %{tmp_dir: tmp_dir} do
      names = [:"a\tb", :"c\nd", :"e\\f", :"g\rh", :"\\t"]

      defs =
        for name <- names do
          quote do
            def unquote(name)(), do: :ok
          end
        end

      [{_, beam}] =
        Code.compile_quoted(
          quote do
            defmodule Argus.TsvTest.OddNames do
              (unquote_splicing(defs))
            end
          end
        )

      assert {:ok, facts_dir} = Argus.Analysis.extract_facts([beam], [:structure])

      rules = Path.join(tmp_dir, "names.dl")

      File.write!(rules, """
      .decl function_def(func: symbol, mod: symbol, name: symbol, arity: number, exported: number)
      .input function_def
      .decl name(name: symbol)
      .output name
      name(n) :- function_def(_, "Argus.TsvTest.OddNames", n, 0, 1).
      """)

      try do
        assert {:ok, %{"name" => rows}} = Souffle.run(facts_dir, rules)
        found = List.flatten(rows)

        for name <- names, do: assert(Atom.to_string(name) in found)
      after
        File.rm_rf(Path.dirname(facts_dir))
      end
    end
  end
end
