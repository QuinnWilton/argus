defmodule Argus.Findings.RunnerStoreTest do
  @moduledoc """
  The runner through a store (`cache:`) and with a solve cache: the same
  findings as a run without, kept solves read back, and degradation as
  ever. Apart from `Argus.Findings.RunnerTest` so the two run side by
  side.
  """
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Runner

  # They test the store, which ARGUS_NO_CACHE turns off.
  @moduletag :cache
  @moduletag :tmp_dir

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

  describe "through a store" do
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
      modules = [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow]
      opts = [analyses: [:startup, :effects, :ets]]

      afresh = without_durations(Runner.run(modules, opts))
      assert afresh.findings != []
      assert without_durations(Runner.run(modules, [cache: store] ++ opts)) == afresh

      warm = Runner.run(modules, [cache: store, souffle_bin: failing_solves!(dir)] ++ opts)
      assert without_durations(warm) == afresh
      assert store |> Path.join("work") |> File.ls!() == []
    end

    # The stage's failure is a warning as well as the degradation.
    @tag :capture_log
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
end
