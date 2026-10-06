defmodule Argus.SouffleOutputTest do
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Souffle

  @moduletag :tmp_dir

  test "solves and program inspection suppress compiler warnings", %{tmp_dir: dir} do
    program = Path.join(dir, "warning.dl")

    # The unused y deliberately produces a warning in both Souffle 2.4 and 2.5.
    File.write!(program, """
    .decl source(x: number, y: number)
    source(1, 2).
    .decl out(x: number)
    .output out
    out(x) :- source(x, y).
    """)

    {diagnostics, 0} =
      System.cmd(Souffle.executable(), ["--warn=all", "-D", dir, program], stderr_to_stdout: true)

    assert diagnostics =~ "Variable y only occurs once"

    # Capture the subprocess's stderr without changing the VM's shared IO devices.
    bin = Path.join(dir, "souffle")
    File.ln_s!(Souffle.executable(), Path.join(dir, "real-souffle"))

    File.write!(bin, ~S"""
    #!/bin/sh
    exec "$(dirname "$0")/real-souffle" "$@" 2>"$(dirname "$0")/diagnostics"
    """)

    File.chmod!(bin, 0o755)
    captured = Path.join(dir, "diagnostics")

    assert {:ok, %{"out" => [["1"]]}} = Souffle.run(dir, program, souffle_bin: bin)
    assert File.read!(captured) == ""

    assert :ok = Souffle.execute_into(bin, dir, program, dir, 10_000)
    assert File.read!(captured) == ""

    assert {:ok, %{outputs: [{"out", "out.csv"}]}} = Souffle.ram_io(bin, program)
    assert File.read!(captured) == ""
  end

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
