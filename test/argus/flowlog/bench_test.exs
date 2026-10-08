defmodule Argus.FlowLog.BenchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Argus.FlowLog.Bench

  @moduletag :flowlog
  @moduletag :tmp_dir

  @program """
  .decl edge(x: symbol, y: symbol) mutable
  .input edge
  .decl blocked(x: symbol) mutable
  .input blocked
  .decl reach(x: symbol, y: symbol)
  reach(x, y) :- edge(x, y).
  reach(x, z) :- reach(x, y), edge(y, z).
  .output reach
  .decl open(x: symbol, y: symbol)
  open(x, y) :- reach(x, y), !blocked(y).
  .output open
  """

  setup %{tmp_dir: tmp} do
    program = Path.join(tmp, "bench.dl")
    File.write!(program, @program)
    %{program: program}
  end

  defp facts!(dir, relations) do
    File.mkdir_p!(dir)

    for {name, rows} <- relations,
        do: File.write!(Path.join(dir, "#{name}.facts"), Argus.Tsv.encode(rows))

    dir
  end

  defp chain(n), do: for(i <- 1..n, do: ["n#{i}", "n#{i + 1}"])

  test "measures a solve, its edits and its engine's memory, with every output's rows",
       %{program: program, tmp_dir: tmp} do
    facts = facts!(Path.join(tmp, "facts"), edge: chain(20), blocked: [["n3"]])

    assert {:ok, measure} = Bench.measure(facts, program, runs: 2, edits: 3, engine: :generic)

    assert measure.outcome == "ok"
    assert measure.engine == :generic
    assert length(measure.cold_ms) == 2
    # Each edit is a row taken out and one put back.
    assert length(measure.edit_ms) == 6
    assert measure.peak_bytes >= measure.bytes and measure.bytes > 0
    assert %{"reach" => %{rows: 210}, "open" => %{rows: open}} = measure.outputs
    # Every path but the two that end at n3.
    assert open == 208
  end

  test "names the programs it can measure, and what the others lack",
       %{program: program, tmp_dir: tmp} do
    facts = facts!(Path.join(tmp, "facts"), edge: chain(2))

    assert Bench.programs(facts, [program]) == {[], [{program, ["blocked"]}]}
  end

  test "a saved run reads back as it was measured, and compares the same with itself",
       %{program: program, tmp_dir: tmp} do
    facts = facts!(Path.join(tmp, "facts"), edge: chain(5), blocked: [])
    {:ok, measure} = Bench.measure(facts, program, edits: 1, engine: :generic)
    saved = Path.join(tmp, "bench.json")

    :ok = Bench.write!(saved, [measure])
    assert Bench.read!(saved) == [measure]
    assert [%{outputs: :same, peak: peak}] = Bench.compare(Bench.read!(saved), [measure])
    assert peak == 1.0
  end

  test "comparing runs over other rows names each output that differs",
       %{program: program, tmp_dir: tmp} do
    before = facts!(Path.join(tmp, "before"), edge: chain(5), blocked: [])
    now = facts!(Path.join(tmp, "now"), edge: chain(5), blocked: [["n2"]])
    {:ok, was} = Bench.measure(before, program, edits: 0, engine: :generic)
    {:ok, is} = Bench.measure(now, program, edits: 0, engine: :generic)

    assert [%{outputs: [{"open", 15, 14}]}] = Bench.compare([was], [is])
  end

  test "a file that is not a saved run is refused, naming it", %{tmp_dir: tmp} do
    path = Path.join(tmp, "other.json")
    File.write!(path, ~s({"rows": []}))

    assert_raise ArgumentError, ~r/other.json is not a benchmark's results/, fn ->
      Bench.read!(path)
    end
  end

  test "mix argus.flowlog bench saves a run, and says a later one found the same rows",
       %{program: program, tmp_dir: tmp} do
    facts = facts!(Path.join(tmp, "facts"), edge: chain(5), blocked: [])
    saved = Path.join(tmp, "saved.json")
    bench = fn args -> Mix.Tasks.Argus.Flowlog.run(["bench", facts, program | args]) end

    first = capture_io(fn -> bench.(["--save", saved, "--engine", "generic"]) end)
    assert first =~ ~r/bench\.dl +generic×1  cold [\d.]+s  edit \d+ms  peak \d+ MB/
    assert first =~ "saved 1 measure(s)"

    again = capture_io(fn -> bench.(["--against", saved, "--engine", "generic"]) end)
    assert again =~ ~r/cold [\d.]+s \([+-]?\d+%\)/
    assert again =~ "every output is the same rows as the saved run's (1 programs)"
  end

  test "a run's total sums its times and what its engines keep, and takes the largest peak" do
    measure = fn cold, edits, peak, bytes ->
      %{cold_ms: cold, edit_ms: edits, peak_bytes: peak, bytes: bytes}
    end

    assert Bench.total([measure.([30, 10], [5, 1, 3], 100, 40), measure.([7], [], nil, nil)]) ==
             %{cold_ms: 17, edit_ms: 3, peak_bytes: 100, bytes: 40}
  end

  test "the median and the fastest of times" do
    assert Bench.median([3, 1, 2]) == 2
    assert Bench.median([]) == nil
    assert Bench.fastest([3, 1, 2]) == 1
    assert Bench.fastest([]) == nil
  end
end
