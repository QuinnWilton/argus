defmodule Argus.SouffleOutputTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle

  @moduletag :tmp_dir

  # A merged relation fills a column that does not apply with the empty
  # symbol, and that column may be first or last: the reader must keep
  # every tab-separated field, edge rows included.
  @program """
  .decl out(a: symbol, b: symbol, c: symbol)
  .output out
  out("", "x", "").
  out("y", "", "z").
  """

  test "empty symbol columns survive at either edge of a row", %{tmp_dir: dir} do
    unless Souffle.available?(), do: flunk("souffle not installed")

    facts = Path.join(dir, "facts")
    File.mkdir_p!(facts)
    program = Path.join(dir, "edges.dl")
    File.write!(program, @program)

    {:ok, %{"out" => rows}} = Souffle.run(facts, program)
    assert Enum.sort(rows) == [["", "x", ""], ["y", "", "z"]]
  end

  # Souffle writes a relation in the order of its symbols' numbers, which
  # is the order it met them in: here "b" before "a", the order of the
  # rules. Where it meets them first in an analysis moves with the
  # solver's version (Souffle 2.4 and 2.5 order one relation's rows apart
  # on the same facts), so rows are read back sorted: an analysis's rows
  # are a function of its input alone.
  @unsorted """
  .decl out(a: symbol, b: symbol)
  .output out
  out("b", "2").
  out("a", "1").
  """

  describe "rows come back sorted, whatever order Souffle wrote them in" do
    setup %{tmp_dir: dir} do
      unless Souffle.available?(), do: flunk("souffle not installed")

      program = Path.join(dir, "unsorted.dl")
      File.write!(program, @unsorted)
      %{program: program}
    end

    test "from a solve", %{tmp_dir: dir, program: program} do
      facts = Path.join(dir, "facts")
      File.mkdir_p!(facts)
      out = Path.join(dir, "out")
      File.mkdir_p!(out)

      {:ok, %{"out" => rows}} = Souffle.run(facts, program, output_dir: out)

      # The precondition: the file holds them unsorted.
      assert out |> Path.join("out.csv") |> File.read!() |> Argus.Tsv.decode() ==
               [["b", "2"], ["a", "1"]]

      assert rows == [["a", "1"], ["b", "2"]]
    end

    test "from a solve the graph kept", %{tmp_dir: dir, program: program} do
      store = Path.join(dir, "store")

      assert {:ok, %{"out" => rows}} =
               Argus.analyze([Argus.Test.Fixtures.Quiet], {:custom, program}, store: store)

      assert rows == [["a", "1"], ["b", "2"]]
    end
  end
end
