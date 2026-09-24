defmodule Argus.Analyses.ShutdownTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.Helpers
  alias Argus.Souffle
  alias Argus.Test.Fixtures.Shutdown, as: S
  alias Argus.Test.Rows

  @all [
    S.Leaks,
    S.Traps,
    S.LeaksIndirect,
    S.LogsOnly,
    S.ReadsOnly,
    S.Unclear,
    S.UnclearTraps,
    S.Lease,
    S.Truncatable,
    S.CleansUpElsewhere
  ]

  # Every test reads the same solve of @all: solved once, read-only.
  setup_all do
    %{solved: Argus.analyze(@all, :shutdown)}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp results(%{solved: solved}) do
    assert {:ok, r} = solved
    r
  end

  defp rows(r, "cleanup_never_runs"),
    do: Rows.where(r, :shutdown, "cleanup_defect", kind: "never_runs", drop: [:kind])

  defp rows(r, "cleanup_unclear"),
    do: Rows.where(r, :shutdown, "cleanup_defect", kind: "unclear", drop: [:kind, :category])

  defp rows(r, "terminate_may_be_truncated"),
    do: Rows.where(r, :shutdown, "cleanup_defect", kind: "truncated", drop: [:kind])

  defp rows(r, "terminate_calls_sibling"),
    do:
      Rows.where(r, :shutdown, "teardown_touches_sibling",
        phase: "terminate",
        drop: [:phase, :kind]
      )

  defp rows(r, relation), do: Map.get(r, relation, [])

  defp modules(r, relation),
    do: r |> rows(relation) |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()

  defp named?(mods, fragment), do: Enum.any?(mods, &String.contains?(&1, fragment))

  # Matches the module column exactly. `Shutdown.Leaks` is a prefix of
  # `Shutdown.LeaksIndirect`, so a contains-check would silently conflate
  # the two positives and let either one satisfy both tests.
  defp only(r, relation, suffix) do
    r |> rows(relation) |> Enum.filter(&String.ends_with?(hd(&1), suffix))
  end

  describe "terminate_calls_sibling" do
    test "a call to a sibling from terminate/2 is reported; a cast is not" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ShutdownSiblings, as: Sib

      {:ok, r} =
        Argus.analyze(
          [Sib.Sup, Sib.Producer, Sib.Watchman, Sib.CarefulWatchman],
          :shutdown
        )

      pairs =
        r
        |> rows("terminate_calls_sibling")
        |> Enum.map(fn [mod, sib, _via, _sup | _sites] -> {mod, sib} end)
        |> Enum.uniq()

      assert pairs == [
               {"Argus.Test.Fixtures.ShutdownSiblings.Watchman",
                "Argus.Test.Fixtures.ShutdownSiblings.Producer"}
             ]

      # The finding points at the call into the sibling's API, and at the
      # supervisor that places both.
      sites =
        r
        |> rows("terminate_calls_sibling")
        |> Enum.map(fn [_mod, _sib, _via, _sup, _handler, site, sup_site] -> {site, sup_site} end)

      assert Enum.all?(sites, fn {site, sup_site} ->
               match?({:ok, _}, Argus.InstrId.parse(site)) and
                 match?({:ok, _}, Argus.InstrId.parse(sup_site))
             end)
    end
  end

  describe "terminate_calls_sibling: which sibling the supervisor has stopped" do
    alias Argus.Test.Fixtures.SiblingOrder, as: O

    defp kinds(sup, extra \\ []) do
      {:ok, r} = Argus.analyze([sup, O.Writer, O.Directory | extra], :shutdown)

      r
      |> Rows.where(:shutdown, "teardown_touches_sibling", phase: "terminate")
      |> Enum.map(fn [mod, sib, _phase, kind | _] -> {kind, mod, sib} end)
      |> Enum.uniq()
    end

    @writer "Argus.Test.Fixtures.SiblingOrder.Writer"
    @directory "Argus.Test.Fixtures.SiblingOrder.Directory"

    test "a sibling started after the caller is stopped first on shutdown" do
      skip_without_souffle()
      assert kinds(O.CalleeStartsLater) == [{"call", @writer, @directory}]
    end

    test "a caller that does not trap exits is not terminated by the shutdown" do
      skip_without_souffle()

      {:ok, r} =
        Argus.analyze([O.NonTrappingCalleeLater, O.NonTrappingWriter, O.Directory], :shutdown)

      assert Rows.where(r, :shutdown, "teardown_touches_sibling", phase: "terminate") == []
    end

    test "a sibling started before the caller is still up, under one_for_one" do
      skip_without_souffle()
      assert kinds(O.CalleeStartsEarlier) == []
    end

    test "under rest_for_one, the earlier sibling's crash is what terminates the caller" do
      skip_without_souffle()
      assert kinds(O.CalleeEarlierRestForOne) == [{"call_restart", @writer, @directory}]
    end

    test "a caller nested in an earlier branch finds a later sibling stopped" do
      skip_without_souffle()
      assert kinds(O.NestedCallerFirst, [O.WriterSup]) == [{"call", @writer, @directory}]
    end

    test "a sibling nested in a later branch is stopped before the caller" do
      skip_without_souffle()
      assert kinds(O.NestedCalleeLater, [O.DirectorySup]) == [{"call", @writer, @directory}]
    end

    test "under rest_for_one, an earlier child's crash takes down a later branch's caller" do
      skip_without_souffle()

      assert kinds(O.NestedCallerRestForOne, [O.WriterSup]) ==
               [{"call_restart", @writer, @directory}]
    end

    test "a sibling nested in an earlier branch is restarted there, leaving the caller" do
      skip_without_souffle()
      assert kinds(O.NestedCalleeRestForOne, [O.DirectorySup]) == []
    end

    test "an earlier sibling under a strategy argus cannot read is reported less surely" do
      skip_without_souffle()
      assert kinds(O.CalleeEarlierUnknownStrategy) == [{"call_unordered", @writer, @directory}]

      {:ok, findings} =
        Argus.run_analyses([O.CalleeEarlierUnknownStrategy, O.Writer, O.Directory],
          analyses: [:shutdown]
        )

      [f] = Enum.filter(findings.findings, &(&1.title =~ "terminate/2 calls a sibling"))
      assert f.severity == :info
      assert f.at_label =~ "unknown"
    end
  end

  describe "terminate_calls_sibling: the try that covers the call" do
    alias Argus.Test.Fixtures.SiblingGuard, as: G

    @guard_fixtures [
      G.Sup,
      G.Directory,
      G.CallInside,
      G.TryElsewhere,
      G.HelperInside,
      G.HelperGuards,
      G.HelperTryElsewhere,
      G.ErrorOnly,
      G.NestedOuterExit,
      G.NestedAfterInner,
      G.NoprocInside,
      G.ClosureTryElsewhere,
      G.ClosureInside,
      G.RefTryElsewhere,
      G.ClosureInTask,
      G.NoprocBare,
      G.ShutdownClauseFirst,
      G.OtherReasonFirst
    ]

    test "only a try covering the call, or the call toward it, guards it" do
      skip_without_souffle()
      {:ok, r} = Argus.analyze(@guard_fixtures, :shutdown)

      callers =
        r
        |> rows("terminate_calls_sibling")
        |> Enum.map(fn [mod | _] -> mod |> String.split(".") |> List.last() end)
        |> Enum.uniq()
        |> Enum.sort()

      # Guarded: CallInside (the call inside the exit-catching try),
      # HelperInside (the call into the helper inside it), HelperGuards
      # (the helper's own try around its call), NestedOuterExit (an outer
      # try takes the exit the inner one lets through), NoprocInside (the
      # handler names :noproc), ClosureInside (the Enum.each that runs the
      # closure is inside the try), ClosureInTask (the call runs in a task
      # terminate/2 does not wait for), ShutdownClauseFirst (the call is in
      # the clause for reasons other than :shutdown).
      assert callers == [
               # the closure's Enum.each follows an unrelated try's end
               "ClosureTryElsewhere",
               # the try around the call takes only errors
               "ErrorOnly",
               # the helper's try covers another call, not the sibling's
               "HelperTryElsewhere",
               # past the inner try's end, the outer one takes only errors
               "NestedAfterInner",
               # a bare :noproc never matches a call's {:noproc, _} exit
               "NoprocBare",
               # the clause for :normal comes first; :shutdown takes the next
               "OtherReasonFirst",
               # the function reference's Enum.each follows the try's end
               "RefTryElsewhere",
               # the try covers another call; the sibling call follows it
               "TryElsewhere"
             ]
    end

    test "the path starts at the call after the try, not the one inside it" do
      skip_without_souffle()
      {:ok, r} = Argus.analyze(@guard_fixtures, :shutdown)
      mod = "Argus.Test.Fixtures.SiblingGuard.TryElsewhere"
      terminate = mod <> ":terminate/2"

      [[^terminate, via, call]] =
        r |> Map.get("terminate_path", []) |> Enum.filter(&(hd(&1) == terminate))

      # The helper is the sibling's API; the path starts at terminate/2's
      # call into it, after the try, not at the GenServer.stop inside.
      assert via == "Argus.Test.Fixtures.SiblingGuard.Directory:unregister/1"
      {:ok, %{idx: call_idx}} = Argus.InstrId.parse(call)

      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(G.TryElsewhere)))
      instrs = Helpers.find_function(data.functions, :terminate, 2)

      assert {:ok, G.Directory, :unregister, 1} =
               instrs |> Enum.at(call_idx) |> Helpers.match_remote_call()
    end
  end

  describe "foreign_dynamic_children" do
    test "children started under another tree are reported unless terminate/2 stops them" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ForeignChildren, as: F

      {:ok, r} =
        Argus.analyze(
          [
            F.LibraryTree,
            F.AppTree,
            F.Worker,
            F.Manager,
            F.TidyManager,
            F.TaskTree,
            F.TaskStarter
          ],
          :shutdown
        )

      assert modules(r, "foreign_dynamic_children") == [
               "Argus.Test.Fixtures.ForeignChildren.Manager",
               "Argus.Test.Fixtures.ForeignChildren.TaskStarter"
             ]
    end
  end

  describe "detection" do
    test "durable cleanup without trap_exit is reported", ctx do
      skip_without_souffle()

      assert [[mod, behaviour, "io", api, via]] =
               only(results(ctx), "cleanup_never_runs", "Shutdown.Leaks")

      assert mod =~ "Shutdown.Leaks"
      assert behaviour == "GenServer"
      assert api =~ "write"
      assert via =~ "terminate"
    end

    test "cleanup several calls below terminate/2 is attributed to its site", ctx do
      skip_without_souffle()

      assert [[_mod, _b, "io", _api, via]] =
               only(results(ctx), "cleanup_never_runs", "LeaksIndirect")

      assert via =~ "persist", "blamed terminate/2 rather than the function at fault"
    end

    test "unclassified work in terminate/2 is reported separately", ctx do
      skip_without_souffle()

      mods = modules(results(ctx), "cleanup_unclear")

      assert named?(mods, "Shutdown.Unclear"),
             "a call into the application's own code is where most cleanup lives"

      refute named?(mods, "UnclearTraps"), "trapping means the callback is reached"
    end

    test "unbounded work is reported when the module does trap", ctx do
      skip_without_souffle()

      assert [[mod, _b, "network", api, _via]] = rows(results(ctx), "terminate_may_be_truncated")
      assert mod =~ "Truncatable"
      assert api =~ "request"
    end
  end

  describe "the claim is the missing trap, not the cleanup" do
    # Every positive above has a twin that does identical work while
    # trapping. If those twins were also reported, the analysis would be
    # detecting "has a terminate/2" and nothing else.
    test "the same cleanup is not reported when the module traps exits", ctx do
      skip_without_souffle()

      mods = modules(results(ctx), "cleanup_never_runs")

      assert named?(mods, "Shutdown.Leaks")
      refute named?(mods, "Shutdown.Traps"), "trapping means terminate/2 actually runs"
    end
  end

  describe "evidence quality" do
    # The verdict being right is not enough if the evidence is wrong. An
    # earlier version used the unbounded call_reachable closure and credited
    # Sequin's MutexOwner with `:ets.insert/2 via :wpool_pool:store_wpool/1`
    # — connection-pool internals five hops down Mutex.release -> Redis ->
    # wpool. Right module, meaningless witness, and indistinguishable from
    # luck until read against source.
    test "cleanup is attributed within a few hops of terminate/2", ctx do
      skip_without_souffle()

      assert [[_mod, _b, "io", api, via]] =
               only(results(ctx), "cleanup_never_runs", "LeaksIndirect")

      assert via =~ "persist", "two hops is inside the bound"
      assert api =~ "write"
    end
  end

  describe "what is deliberately not reported" do
    test "logging is not cleanup", ctx do
      skip_without_souffle()
      r = results(ctx)

      refute named?(modules(r, "cleanup_never_runs"), "LogsOnly")
      refute named?(modules(r, "cleanup_unclear"), "LogsOnly")
    end

    test "reads have nothing to lose by being skipped", ctx do
      skip_without_souffle()
      r = results(ctx)

      refute named?(modules(r, "cleanup_never_runs"), "ReadsOnly")
      refute named?(modules(r, "cleanup_unclear"), "ReadsOnly")
    end

    test "cleanup outside terminate/2 is not this analysis's business", ctx do
      skip_without_souffle()

      refute named?(modules(results(ctx), "cleanup_never_runs"), "CleansUpElsewhere")
    end

    test "a module with classified cleanup is not also reported as unclear", ctx do
      skip_without_souffle()

      # Otherwise the precise finding and the vague one would name the same
      # module, and the vague one adds nothing.
      assert named?(modules(results(ctx), "cleanup_never_runs"), "Shutdown.Leaks")
      refute named?(modules(results(ctx), "cleanup_unclear"), "Shutdown.Leaks")
    end
  end

  describe "findings" do
    test "each relation renders a finding naming the module and the fix" do
      mod = Argus.Analyses.Shutdown

      never =
        mod.finding(:cleanup_defect, [
          "My.Server",
          "GenServer",
          "never_runs",
          "io",
          "File.write/2",
          "f"
        ])

      assert never.severity == :error
      assert Enum.any?(never.help, &(&1 =~ "trap_exit"))
      assert never.detail =~ "file I/O"

      unclear =
        mod.finding(:cleanup_defect, [
          "My.Server",
          "GenServer",
          "unclear",
          "",
          "Lease.release/1",
          "f"
        ])

      assert unclear.severity == :warning
      assert unclear.detail =~ "cannot classify"

      trunc_ =
        mod.finding(:cleanup_defect, [
          "My.Server",
          "GenServer",
          "truncated",
          "network",
          "httpc.request/1",
          "f"
        ])

      assert trunc_.severity == :warning
      assert trunc_.detail =~ "shutdown timeout"
    end
  end
end
