defmodule Argus.Dl.ProgramTest do
  @moduledoc """
  A Datalog program as a solve reads it (`Argus.Dl.Program`), and what
  it reads (`Argus.FlowLog.input_relations/2`).
  """
  use ExUnit.Case, async: true

  alias Argus.Dl.Program

  @moduletag :tmp_dir

  # A program over `edge` that includes its output's rule from a second
  # file, as the shipped programs include their clientlib.
  defp program!(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/path.dl"), """
    path(x, y) :- edge(x, y).
    """)

    File.write!(Path.join(dir, "p.dl"), """
    .decl edge(x: symbol, y: symbol) mutable
    .input edge
    .decl path(x: symbol, y: symbol)
    .output path
    .include "lib/path.dl"
    """)

    facts = Path.join(dir, "facts")
    File.mkdir_p!(facts)
    File.write!(Path.join(facts, "edge.facts"), "a\tb\n")
    {Path.join(dir, "p.dl"), facts}
  end

  describe "input files" do
    @describetag :flowlog

    test "are the files the program reads, named by a filename it gives",
         %{tmp_dir: tmp} do
      rules = Path.join(tmp, "q.dl")

      File.write!(rules, """
      .decl a(x: symbol) mutable
      .input a
      .decl b(x: symbol) mutable
      .input b(filename="other.facts")
      .decl unused(x: symbol) mutable
      .input unused
      .decl out(x: symbol)
      .output out
      out(x) :- a(x), b(x).
      """)

      assert {:ok, ["a.facts", "other.facts"]} = Argus.FlowLog.input_files(rules)
      assert {:ok, ["a", "b"]} = Argus.FlowLog.input_relations(rules)
    end
  end

  describe "program_digest/1" do
    test "is the program and its includes, wherever the tree is", %{tmp_dir: tmp} do
      {one, _} = program!(Path.join(tmp, "one"))
      {two, _} = program!(Path.join(tmp, "two"))

      assert Program.program_digest(one) == Program.program_digest(two)

      assert Program.program_files(one) == [
               {"p.dl", one},
               {"lib/path.dl", Path.join([tmp, "one", "lib", "path.dl"])}
             ]
    end
  end

  describe "stamped/2" do
    test "computes again once a file it read has moved, if only in content",
         %{tmp_dir: tmp} do
      file = Path.join(tmp, "input")
      File.write!(file, "one")
      key = {__MODULE__, make_ref()}
      compute = fn -> {[file], File.read!(file)} end

      assert Program.stamped(key, compute) == "one"
      File.write!(file, "two")
      # Within the second the value is trusted without a stat.
      assert Program.stamped(key, compute) == "one"

      Process.sleep(1_100)
      assert Program.stamped(key, compute) == "two"
    end
  end
end
