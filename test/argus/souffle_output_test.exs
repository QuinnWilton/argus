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
end
