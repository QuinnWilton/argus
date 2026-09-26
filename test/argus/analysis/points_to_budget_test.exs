defmodule Argus.Analysis.PointsToBudgetTest do
  @moduledoc """
  Which points-to stage runs is a function of the facts
  (`Argus.Analysis.Extraction.derive_points_to/2`): the exact stage
  within its row budget (`priv/dl/points_to.dl`'s `.limitsize`), the
  bounded one past it, and a failure, never a switch of stage, when the
  solver runs out of time.

  The programs are PidFlow's summaries written by hand: a merge
  function `merge/1` whose parameter every caller hands a term holding
  the one registered process, and which hands that parameter on to
  `helpers` helpers. Each helper's parameter then points to every
  caller's term, `callers × helpers` rows of `source_pts` built from
  `callers + helpers` rows of facts: the shape of the merged heap that
  outgrew the exact stage on Ash. A call in `merge/1` on the term's
  field reaches the process from every caller.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Argus.{Analysis, Souffle}
  alias Argus.Test.Fixtures.PidFlow

  @moduletag :tmp_dir

  # Past the budget (500,000 rows): 800 × 700 = 560,000 parameter rows.
  @over {800, 700}
  @within {40, 30}

  @proc "spawn M:start/0#1"

  setup do
    unless Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  # A facts directory holding every relation the stage reads, empty but
  # for the merged heap's summaries.
  defp merged_heap!(dir, {callers, helpers}) do
    File.mkdir_p!(dir)
    {:ok, inputs} = Souffle.input_files(Analysis.points_to_rules_path())
    for file <- inputs, do: File.write!(Path.join(dir, file), "")

    merge = "M:merge/1"

    write!(dir, "process_start", [["s0", "M:start/0", @proc, "spawn", "M:loop/0"]])
    write!(dir, "pid_register", [["r0", "M:start/0", "reg", "proc", @proc]])

    write!(
      dir,
      "pid_object",
      for(i <- 1..callers, do: ["M:c#{i}/0", "o#{i}", "tuple", "", "1"])
    )

    write!(
      dir,
      "pid_field",
      for(i <- 1..callers, do: ["M:c#{i}/0", "o#{i}", "{0}", "name", "reg"])
    )

    write!(
      dir,
      "pid_arg",
      for(i <- 1..callers, do: ["a#{i}", "M:c#{i}/0", merge, "0", "call", "obj", "o#{i}"]) ++
        for(j <- 1..helpers, do: ["b#{j}", merge, "M:h#{j}/1", "0", "call", "param", "0"])
    )

    write!(dir, "pid_load", [[merge, "l0", "{0}", "param", "0"]])
    write!(dir, "pid_call", [["k0", merge, "call", "load", "l0"]])
    dir
  end

  defp write!(dir, relation, rows) do
    File.write!(Path.join(dir, relation <> ".facts"), Argus.Tsv.encode(rows))
  end

  # A solver that sleeps before every run.
  defp slowed!(dir, seconds) do
    bin = Path.join(dir, "souffle-slowed")

    File.write!(bin, """
    #!/bin/sh
    sleep #{seconds}
    exec #{System.find_executable("souffle")} "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  # A solver that says every solve of `program` (a pattern of its file
  # name) outgrew the budget, whatever it found.
  defp overflowing!(dir, program) do
    bin = Path.join(dir, "souffle-overflowing")

    File.write!(bin, """
    #!/bin/sh
    out=""
    last=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-D" ]; then out="$arg"; fi
      prev="$arg"
      last="$arg"
    done
    #{System.find_executable("souffle")} "$@" || exit $?
    case "$out:$last" in
      ?*:*#{program}) printf 'source_pts\\t500000\\t500000\\n' > "$out/points_to_overflow.csv" ;;
    esac
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  defp staged(dir) do
    Map.new(Analysis.points_to_relations(), fn relation ->
      {relation, File.read!(Path.join(dir, relation <> ".facts"))}
    end)
  end

  defp staged_nothing?(dir),
    do:
      not Enum.any?(Analysis.points_to_relations(), &File.exists?(Path.join(dir, &1 <> ".facts")))

  defp rows(dir, relation),
    do: dir |> Path.join(relation <> ".facts") |> File.read!() |> Argus.Tsv.decode()

  test "a program within the budget runs the exact stage", %{tmp_dir: tmp} do
    dir = merged_heap!(Path.join(tmp, "within"), @within)

    assert :ok = Analysis.derive_points_to(dir)
    assert rows(dir, "points_to_mode") == [["exact"]]
    {callers, _} = @within
    assert length(rows(dir, "process_call")) == callers
  end

  test "a program whose fixpoint outgrows the budget runs bounded, its pervasive leaf coarsely",
       %{tmp_dir: tmp} do
    dir = merged_heap!(Path.join(tmp, "over"), @over)

    log = capture_log(fn -> assert :ok = Analysis.derive_points_to(dir) end)

    assert log =~ "outgrew its budget (source_pts reached"
    assert log =~ "resolving 1 pervasive leaves coarsely (#{@proc})"
    assert rows(dir, "points_to_mode") == [["bounded"]]
    # What it reported is read back, not left among the facts.
    refute File.exists?(Path.join(dir, "pervasive.csv"))

    # The same targets the exact stage would find: every caller's term
    # holds the process, and merge/1 calls it for each.
    {callers, _} = @over
    targets = rows(dir, "process_call")
    assert length(targets) == callers
    assert Enum.all?(targets, &(List.last(&1) == @proc))
    assert rows(dir, "call_site_target") == [["k0", "M:merge/1", "call", @proc]]
  end

  @tag :capture_log
  test "which stage runs is a function of the facts, not of the solver's speed",
       %{tmp_dir: tmp} do
    slow = slowed!(tmp, 1)

    for {name, size} <- [within: @within, over: @over] do
      fast = merged_heap!(Path.join(tmp, "#{name}-fast"), size)
      slowed = merged_heap!(Path.join(tmp, "#{name}-slow"), size)

      assert :ok = Analysis.derive_points_to(fast)
      assert :ok = Analysis.derive_points_to(slowed, souffle_bin: slow)
      assert staged(slowed) == staged(fast), "#{name}: a slower solver staged other rows"
    end
  end

  # A failed stage stages nothing, and leaves a directory as it found
  # it: rows an earlier derivation staged over the same facts are the
  # answer, and another derivation into the directory may be reading
  # them. `fail` derives into a directory and returns the log.
  defp fails_as_found!(tmp, name, fail) do
    fresh = merged_heap!(Path.join(tmp, name), @within)
    staged_dir = merged_heap!(Path.join(tmp, name <> "-staged"), @within)
    assert :ok = Analysis.derive_points_to(staged_dir)
    before = staged(staged_dir)

    log = capture_log(fn -> Enum.each([fresh, staged_dir], fail) end)

    assert staged_nothing?(fresh)
    assert staged(staged_dir) == before
    # Nothing else is left behind: no report, no solve's own directory.
    assert Enum.sort(File.ls!(staged_dir)) ==
             Enum.sort(File.ls!(fresh) ++ Enum.map(Map.keys(before), &"#{&1}.facts"))

    log
  end

  test "a stage that runs out of time fails and stages nothing", %{tmp_dir: tmp} do
    slow = slowed!(tmp, 5)

    log =
      fails_as_found!(tmp, "late", fn dir ->
        assert {:error, {:points_to, :souffle_timeout}} =
                 Analysis.derive_points_to(dir, souffle_bin: slow, souffle_timeout: 500)
      end)

    assert log =~ "did not finish within :souffle_timeout"
  end

  test "a stage that outgrows the budget even bounded fails and stages nothing",
       %{tmp_dir: tmp} do
    overflowing = overflowing!(tmp, "points_to*.dl")

    log =
      fails_as_found!(tmp, "over-bounded", fn dir ->
        assert {:error, {:points_to, {:over_budget, [{"source_pts", 500_000, 500_000}]}}} =
                 Analysis.derive_points_to(dir, souffle_bin: overflowing)
      end)

    assert log =~ "outgrew its budget even bounded"
  end

  describe "through a store" do
    @describetag :cache

    # A solver that answers what a warm run asks and fails any solve.
    defp no_solves!(dir) do
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

    test "the stage's mode is kept with its outputs, and a warm run solves neither stage",
         %{tmp_dir: tmp} do
      store = Path.join(tmp, "store")

      modules =
        for name <- ~w(SafeCall UserA UserB TargetA TargetB), do: Module.concat(PidFlow, name)

      extract = fn bin ->
        {:ok, dir} = Analysis.extract_facts(modules, [:startup], cache: store, souffle_bin: bin)

        try do
          {rows(dir, "points_to_mode"), rows(dir, "process_call")}
        after
          File.rm_rf!(Path.dirname(dir))
        end
      end

      {:ok, exact_dir} = Analysis.extract_facts(modules, [:startup])
      exact = rows(exact_dir, "process_call")
      File.rm_rf!(Path.dirname(exact_dir))

      # The exact solve says it outgrew the budget: the bounded one runs,
      # and over these modules finds nothing pervasive.
      cold = capture_log(fn -> send(self(), extract.(overflowing!(tmp, "points_to.dl"))) end)
      assert_received {[["bounded"]], ^exact}
      assert cold =~ "ran it bounded"

      warm = capture_log(fn -> send(self(), extract.(no_solves!(tmp))) end)
      assert_received {[["bounded"]], ^exact}
      assert warm =~ "ran it bounded"
    end
  end
end
