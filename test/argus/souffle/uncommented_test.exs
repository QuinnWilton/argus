defmodule Argus.Souffle.UncommentedTest do
  @moduledoc """
  A program's key reads its text without comment lines
  (`Argus.Souffle.Program.uncommented/1`): an edit to a rule's prose
  solves nothing again. Checked against the solver: every shipped
  program, with a comment line added after every line of every file it
  reads as text, loads the same relations and writes the same files, and
  its key does not move; a change to a rule moves it.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle.Program

  doctest Argus.Souffle.Program, only: [uncommented: 1]

  @moduletag :tmp_dir

  test "a comment line that opens or closes a block comment is kept" do
    for text <- ["a(1).\n// opens /*\nb(2).", "a(1).\n// closes */\nb(2)."] do
      assert Program.uncommented(text) == Enum.join(String.split(text, "\n"), "\n")
    end
  end

  test "a comment after code on its line is code's" do
    assert Program.uncommented("a(1). // why\n") == "a(1). // why"
  end

  test "prose added to every text file moves no program's key; a rule edit does", %{
    tmp_dir: tmp
  } do
    dl = Path.join(tmp, "dl")
    File.cp_r!(Path.join(:code.priv_dir(:panoptes), "dl"), dl)
    programs = Path.wildcard(Path.join(dl, "analyses/*.dl")) ++ [Path.join(dl, "stage0.dl")]
    before = Map.new(programs, &{&1, Program.declared_digest(&1, :all)})

    for file <- Path.wildcard(Path.join(dl, "**/*.dl")),
        content = File.read!(file),
        Program.declarations(content) == :error do
      prose = content |> String.split("\n") |> Enum.map_join("\n", &(&1 <> "\n  // prose"))
      File.write!(file, "// a header\n\n" <> prose <> "\n// a footer\n")
    end

    for program <- programs do
      assert Program.declared_digest(program, :all) == before[program], program
    end

    # The solver agrees: the same outputs over the fixtures' facts.
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    shipped = Path.join(:code.priv_dir(:panoptes), "dl")
    modules = [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow, :gen_server]
    analyses = [:races, :mailbox, :startup]
    {:ok, facts} = Argus.Analysis.extract_facts(modules, analyses, backend: :batch)

    try do
      for analysis <- analyses do
        {:ok, rules} = Argus.Analysis.Catalog.rules_path(analysis)
        copy = Path.join(dl, Path.relative_to(rules, shipped))

        assert Argus.Souffle.run(facts, copy) == Argus.Souffle.run(facts, rules),
               inspect(analysis)
      end
    after
      File.rm_rf!(Path.dirname(facts))
    end

    races = Path.join(dl, "analyses/races.dl")
    File.write!(races, File.read!(races) <> "\n.decl argus_probe(x: symbol)\n")
    refute Program.declared_digest(races, :all) == before[races]
  end
end
