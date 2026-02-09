defmodule Argus.Souffle.CLITest do
  use ExUnit.Case, async: true

  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  # Skip all tests if souffle is not installed.
  setup do
    unless CLI.available?() do
      ExUnit.configure(exclude: [tmp_dir: true])
    end

    :ok
  end

  describe "available?/0" do
    test "returns a boolean" do
      assert is_boolean(CLI.available?())
    end
  end

  describe "run/3" do
    @tag :tmp_dir
    test "runs a trivial Datalog program", %{tmp_dir: tmp_dir} do
      if not CLI.available?(), do: flunk("souffle not installed")

      facts_dir = Path.join(tmp_dir, "facts")
      output_dir = Path.join(tmp_dir, "output")
      rules_path = Path.join(tmp_dir, "test.dl")

      File.mkdir_p!(facts_dir)
      File.mkdir_p!(output_dir)

      # Write a simple edge relation.
      File.write!(Path.join(facts_dir, "edge.facts"), "a\tb\nb\tc\nc\td\n")

      # Write Datalog rules.
      File.write!(rules_path, """
      .decl edge(x: symbol, y: symbol)
      .input edge

      .decl path(x: symbol, y: symbol)
      .output path

      path(x, y) :- edge(x, y).
      path(x, z) :- path(x, y), edge(y, z).
      """)

      assert {:ok, results} = CLI.run(facts_dir, rules_path, output_dir: output_dir)
      assert Map.has_key?(results, "path")

      paths = results["path"]
      # a->b, a->c, a->d, b->c, b->d, c->d = 6 paths.
      assert length(paths) == 6

      # Check a specific path exists.
      assert ["a", "d"] in paths
    end

    @tag :tmp_dir
    test "returns error for invalid rules", %{tmp_dir: tmp_dir} do
      if not CLI.available?(), do: flunk("souffle not installed")

      facts_dir = Path.join(tmp_dir, "facts")
      rules_path = Path.join(tmp_dir, "bad.dl")

      File.mkdir_p!(facts_dir)
      File.write!(rules_path, "this is not valid datalog!!!")

      assert {:error, {:souffle_error, _, _}} = CLI.run(facts_dir, rules_path)
    end

    @tag :tmp_dir
    test "returns souffle_not_found when binary missing", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")
      rules_path = Path.join(tmp_dir, "rules.dl")

      File.mkdir_p!(facts_dir)
      File.write!(rules_path, "")

      assert {:error, :souffle_not_found} =
               CLI.run(facts_dir, rules_path, souffle_bin: nil)
    end
  end
end
