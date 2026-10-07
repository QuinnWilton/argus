defmodule Argus.Analysis.PointsToBudgetTest do
  @moduledoc """
  Which points-to stage runs is a function of the facts
  (`Argus.Analysis.Extraction.derive_points_to/2`): the exact stage
  within its row budget (`priv/dl/points_to.dl`'s `points_to_budget`,
  counted over the finished fixpoint), the bounded one past it, and a
  failure, never a switch of stage, when the engine runs out of time.

  The programs are TermFlow's summaries written by hand: a merge
  function `merge/1` whose parameter every caller hands a term holding
  the one registered process, and which hands that parameter on to
  `helpers` helpers. Each helper's parameter then points to every
  caller's term, `callers × helpers` rows of `source_pts` built from
  `callers + helpers` rows of facts: the shape of the merged heap that
  outgrew the exact stage on Ash. A call in `merge/1` on the term's
  field reaches the process from every caller.
  """
  # Not async: two tests solve copies of the stage programs as argus's own
  # (`:dl_root`, application-wide) or under a failing engine
  # (`Argus.Test.FailingEngine`, a VM-wide variable).
  use ExUnit.Case, async: false
  @moduletag :flowlog
  # The copies' engines are built once per version of the rules.
  @moduletag timeout: 1_800_000

  import ExUnit.CaptureLog

  alias Argus.Analysis
  alias Argus.Test.Files
  alias Argus.Test.Fixtures.PidFlow

  @moduletag :tmp_dir

  # The budget a copy of the rules holds the stages to, and heaps within
  # and past it: the same rules over a few hundred rows instead of half a
  # million, so the tests solve in milliseconds.
  @budget 1_000
  @within {20, 15}
  @over {40, 30}
  # Past the shipped budget (500,000 rows): 800 × 700 = 560,000 parameter
  # rows, for an exact fixpoint slow enough to outlive a short timeout.
  @slow {800, 700}

  @proc "spawn M:start/0#1"

  # A facts directory holding every relation the stage reads, empty but
  # for the merged heap's summaries.
  defp merged_heap!(dir, {callers, helpers}) do
    File.mkdir_p!(dir)
    {:ok, inputs} = Argus.FlowLog.input_files(Analysis.points_to_rules_path())
    for file <- inputs, do: File.write!(Path.join(dir, file), "")

    merge = "M:merge/1"

    write!(dir, "process_start", [["s0", "M:start/0", @proc, "spawn", "M:loop/0"]])
    write!(dir, "process_register_source", [["r0", "M:start/0", "reg", "proc", @proc]])

    write!(
      dir,
      "value_object",
      for(i <- 1..callers, do: ["M:c#{i}/0", "o#{i}", "tuple", "", "1"])
    )

    write!(
      dir,
      "value_field",
      for(i <- 1..callers, do: ["M:c#{i}/0", "o#{i}", "{0}", "name", "reg"])
    )

    write!(
      dir,
      "value_arg",
      for(i <- 1..callers, do: ["a#{i}", "M:c#{i}/0", merge, "0", "call", "obj", "o#{i}"]) ++
        for(j <- 1..helpers, do: ["b#{j}", merge, "M:h#{j}/1", "0", "call", "param", "0"])
    )

    write!(dir, "value_load", [[merge, "l0", "{0}", "param", "0"]])
    write!(dir, "process_call_source", [["k0", merge, "call", "load", "l0"]])
    dir
  end

  defp write!(dir, relation, rows) do
    File.write!(Path.join(dir, relation <> ".facts"), Argus.Tsv.encode(rows))
  end

  # A copy of argus's rules under `dir`, its stage programs edited by
  # `edit` (`%{relative_path => fun(text) -> text}`): what an engine
  # built for them answers.
  defp rules_copy!(dir, edits) do
    root = Path.join(dir, "dl")
    File.cp_r!(Argus.Dl.root(), root)

    for {file, edit} <- edits do
      path = Path.join(root, file)
      File.write!(path, edit.(File.read!(path)))
    end

    root
  end

  # Both stages held to `@budget` rows, as the paths a derivation takes.
  defp budgeted!(tmp) do
    dir = Path.join(tmp, "budgeted")
    File.mkdir_p!(dir)

    # A leaf is pervasive past a thousand holders, as many as these heaps
    # hold in all: the copy scales that down with the budget.
    rules =
      rules_copy!(dir, %{
        "points_to.dl" => &String.replace(&1, "500000", "#{@budget}"),
        "clientlib/pervasive.dl" => &String.replace(&1, "n > 1000,", "n > 20,")
      })

    [
      rules_path: Path.join(rules, "points_to.dl"),
      bounded_rules_path: Path.join(rules, "points_to_bounded.dl")
    ]
  end

  # Both stages held to a budget every program here outgrows.
  defp tiny_budget(text), do: String.replace(text, "500000", "10")

  # The exact stage says it outgrew its budget, whatever it found; the
  # bounded one (which includes it) runs as it would.
  defp exact_overflows(text) do
    text <>
      """

      points_to_overflow("source_pts", 1, 0) :- stage_mode("exact"), !stage_mode("bounded").
      """
  end

  defp staged(dir) do
    Map.new(Analysis.points_to_relations(), fn relation ->
      {relation, File.read!(Path.join(dir, relation <> ".facts"))}
    end)
  end

  defp staged_nothing?(dir),
    do:
      not Enum.any?(Analysis.points_to_relations(), &File.exists?(Path.join(dir, &1 <> ".facts")))

  # Sorted: a relation is a set, and the backends write its rows in
  # orders of their own.
  defp rows(dir, relation),
    do:
      dir |> Path.join(relation <> ".facts") |> File.read!() |> Argus.Tsv.decode() |> Enum.sort()

  test "a program within the budget runs the exact stage", %{tmp_dir: tmp} do
    dir = merged_heap!(Path.join(tmp, "within"), @within)

    assert :ok = Analysis.derive_points_to(dir, budgeted!(tmp))
    assert rows(dir, "points_to_mode") == [["exact"]]
    {callers, _} = @within
    assert length(rows(dir, "process_call")) == callers
  end

  test "a program whose fixpoint outgrows the budget runs bounded, its pervasive leaf coarsely",
       %{tmp_dir: tmp} do
    dir = merged_heap!(Path.join(tmp, "over"), @over)
    budgeted = budgeted!(tmp)

    log = capture_log(fn -> assert :ok = Analysis.derive_points_to(dir, budgeted) end)

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
  test "which stage runs is a function of the facts, not of the engine's speed",
       %{tmp_dir: tmp} do
    budgeted = budgeted!(tmp)

    for {name, size} <- [within: @within, over: @over] do
      fast = merged_heap!(Path.join(tmp, "#{name}-fast"), size)
      slowed = merged_heap!(Path.join(tmp, "#{name}-slow"), size)

      assert :ok = Analysis.derive_points_to(fast, [workers: 4] ++ budgeted)
      assert :ok = Analysis.derive_points_to(slowed, [workers: 1] ++ budgeted)
      assert staged(slowed) == staged(fast), "#{name}: a slower engine staged other rows"
    end
  end

  # A failed stage stages nothing, and leaves a directory as it found
  # it: rows an earlier derivation staged over the same facts are the
  # answer, and another derivation into the directory may be reading
  # them. `fail` derives into a directory and returns the log.
  defp fails_as_found!(tmp, name, size \\ @within, fail) do
    fresh = merged_heap!(Path.join(tmp, name), size)
    staged_dir = merged_heap!(Path.join(tmp, name <> "-staged"), size)
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
    # Over the budget, the exact fixpoint alone takes far longer than this.
    log =
      fails_as_found!(tmp, "late", @slow, fn dir ->
        assert {:error, {:points_to, :flowlog_timeout}} =
                 Analysis.derive_points_to(dir, timeout: 50)
      end)

    assert log =~ "did not finish within the solve's timeout"
  end

  test "a stage that outgrows the budget even bounded fails and stages nothing",
       %{tmp_dir: tmp} do
    rules = rules_copy!(tmp, %{"points_to.dl" => &tiny_budget/1})

    copies = [
      rules_path: Path.join(rules, "points_to.dl"),
      bounded_rules_path: Path.join(rules, "points_to_bounded.dl")
    ]

    log =
      fails_as_found!(tmp, "over-bounded", fn dir ->
        assert {:error, {:points_to, {:over_budget, over}}} =
                 Analysis.derive_points_to(dir, copies)

        assert Enum.any?(over, &match?({"source_pts", rows, 10} when rows >= 10, &1))
      end)

    assert log =~ "outgrew its budget even bounded"
  end

  describe "through a store" do
    @describetag :cache

    test "the stage's mode is kept with its outputs, and a warm run solves neither stage",
         %{tmp_dir: tmp} do
      store = Path.join(tmp, "store")

      modules =
        for name <- ~w(SafeCall UserA UserB TargetA TargetB), do: Module.concat(PidFlow, name)

      extract = fn ->
        {:ok, dir} = Analysis.extract_facts(modules, [:startup], store: store)

        try do
          {rows(dir, "points_to_mode"), rows(dir, "process_call")}
        after
          Files.rm_rf!(Path.dirname(dir))
        end
      end

      {:ok, exact_dir} = Analysis.extract_facts(modules, [:startup])
      exact = rows(exact_dir, "process_call")
      Files.rm_rf!(Path.dirname(exact_dir))

      # The exact solve says it outgrew the budget: the bounded one runs,
      # and over these modules finds nothing pervasive.
      Application.put_env(
        :argus_beam,
        :dl_root,
        rules_copy!(tmp, %{"points_to.dl" => &exact_overflows/1})
      )

      try do
        cold = capture_log(fn -> send(self(), extract.()) end)
        assert_received {[["bounded"]], ^exact}
        assert cold =~ "ran it bounded"

        # Neither stage's engine can run now: a warm run reads both back.
        Argus.Test.FailingEngine.with(["points_to.dl", "points_to_bounded.dl"], fn ->
          warm = capture_log(fn -> send(self(), extract.()) end)
          assert_received {[["bounded"]], ^exact}
          assert warm =~ "ran it bounded"
        end)
      after
        Application.delete_env(:argus_beam, :dl_root)
      end
    end
  end
end
