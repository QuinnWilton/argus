defmodule Argus.Findings.RunnerTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Runner

  @moduletag :tmp_dir

  test "an empty selection runs nothing and extracts nothing" do
    assert {:ok, %Findings{findings: [], ran: [], degraded: [], extraction_errors: []}} =
             Runner.run([:fake_module_never_read], analyses: [])
  end

  test "a selection that does not resolve is an error before anything runs" do
    assert {:error, {:unknown_analysis, :nope}} = Runner.run([:lists], analyses: [:nope])
    assert {:error, {:invalid_analyses, "all"}} = Runner.run([:lists], analyses: "all")
  end

  @tag :cache
  test "a solve cache keeps each analysis's solve and the points-to stage's, read back as they were",
       %{tmp_dir: dir} do
    if not Argus.Souffle.available?(), do: flunk("souffle not installed")

    {:ok, facts} =
      Argus.Analysis.extract_facts([:lists], [:startup, :effects], points_to: :deferred)

    solves = Path.join(dir, "solves")

    try do
      assert {:ok, first} =
               Runner.run([:lists],
                 analyses: [:startup, :effects],
                 facts_dir: facts,
                 solve_cache: solves
               )

      kept = solves |> File.ls!() |> Enum.map(&(&1 |> String.split("-") |> hd())) |> Enum.sort()
      assert kept == ["effects", "points_to", "startup"]

      # Read back: the same findings, and nothing solved again.
      assert {:ok, again} =
               Runner.run([:lists],
                 analyses: [:startup, :effects],
                 facts_dir: facts,
                 solve_cache: solves
               )

      assert again.findings == first.findings
      assert length(File.ls!(solves)) == 3
    after
      File.rm_rf(Path.dirname(facts))
    end
  end

  @tag :cache
  test "a solve cache needs no facts directory of the caller's", %{tmp_dir: dir} do
    if not Argus.Souffle.available?(), do: flunk("souffle not installed")
    solves = Path.join(dir, "solves")

    assert {:ok, first} = Runner.run([:lists], analyses: [:effects], solve_cache: solves)
    assert {:ok, again} = Runner.run([:lists], analyses: [:effects], solve_cache: solves)
    assert again.findings == first.findings

    # Stage 0 is a solve like any other.
    kept = solves |> File.ls!() |> Enum.map(&(&1 |> String.split("-") |> hd())) |> Enum.sort()
    assert kept == ["effects", "stage0"]
  end

  # A solver that fails the points-to stage and runs everything else.
  defp failing_points_to!(dir) do
    bin = Path.join(dir, "souffle")

    File.write!(bin, """
    #!/bin/sh
    for arg in "$@"; do last="$arg"; done
    case "$last" in
      *points_to.dl) echo "points-to failed" >&2; exit 3 ;;
    esac
    exec #{System.find_executable("souffle")} "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  test "a failed points-to stage degrades only the analyses that read it", %{tmp_dir: dir} do
    assert {:ok, %Findings{ran: ran, degraded: degraded}} =
             Runner.run([:lists],
               analyses: [:startup, :effects],
               souffle_bin: failing_points_to!(dir)
             )

    assert [%{analysis: :effects}] = ran

    assert [%{analysis: :startup, reason: {:points_to, {:souffle_error, 3, _}}, detail: detail}] =
             degraded

    assert detail =~ "points_to.dl"
  end

  describe "through a store" do
    @describetag :cache

    # A solver that answers what a warm run asks — its version, a
    # program's inputs — and fails any solve.
    defp failing_solves!(dir) do
      bin = Path.join(dir, "souffle-no-solves")

      File.write!(bin, """
      #!/bin/sh
      case " $* " in
        *" -F "*) echo "no solves here" >&2; exit 4 ;;
      esac
      exec #{System.find_executable("souffle")} "$@"
      """)

      File.chmod!(bin, 0o755)
      bin
    end

    defp without_durations({:ok, findings}),
      do: %{findings | ran: Enum.map(findings.ran, &Map.delete(&1, :duration_ms))}

    test "finds what a run without one finds, and a warm run solves nothing",
         %{tmp_dir: dir} do
      store = Path.join(dir, "store")
      modules = [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow, :gen_server]
      opts = [analyses: [:startup, :effects, :races]]

      afresh = without_durations(Runner.run(modules, opts))
      assert without_durations(Runner.run(modules, [cache: store] ++ opts)) == afresh

      warm = Runner.run(modules, [cache: store, souffle_bin: failing_solves!(dir)] ++ opts)
      assert without_durations(warm) == afresh
      assert store |> Path.join("work") |> File.ls!() == []
    end

    test "a failed points-to stage degrades only the analyses that read it",
         %{tmp_dir: dir} do
      assert {:ok, %Findings{ran: ran, degraded: degraded}} =
               Runner.run([:lists],
                 analyses: [:startup, :effects],
                 souffle_bin: failing_points_to!(dir),
                 cache: Path.join(dir, "store")
               )

      assert [%{analysis: :effects}] = ran
      assert [%{analysis: :startup, reason: {:points_to, {:souffle_error, 3, _}}}] = degraded
    end

    test "a failed stage 0 degrades every analysis", %{tmp_dir: dir} do
      assert {:ok, %Findings{ran: [], degraded: degraded}} =
               Runner.run([:lists],
                 analyses: [:startup, :effects],
                 souffle_bin: failing_solves!(dir),
                 cache: Path.join(dir, "store")
               )

      assert Enum.map(degraded, & &1.analysis) == [:startup, :effects]
    end
  end

  describe "extraction_errors/1" do
    test "reads the rows in order, a module that does not parse keeping its source",
         %{tmp_dir: dir} do
      File.write!(
        Path.join(dir, "extraction_error.facts"),
        "Foo.Bar\tArgus.Extractors.Ets\tboom\n/tmp/x.beam\tpipeline\tunreadable\n"
      )

      assert Runner.extraction_errors(dir) == [
               %{
                 module: Foo.Bar,
                 source: "Foo.Bar",
                 step: "Argus.Extractors.Ets",
                 reason: "boom"
               },
               %{module: nil, source: "/tmp/x.beam", step: "pipeline", reason: "unreadable"}
             ]

      assert Findings.extraction_errors(dir) == Runner.extraction_errors(dir)
    end

    test "a directory without the file has none", %{tmp_dir: dir} do
      assert Runner.extraction_errors(dir) == []
    end
  end
end
