defmodule Argus.Analyses.StartupContinueTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp continue_to_later(results),
    do:
      Rows.where(results, :startup, "blocks_on_peer",
        phase: "continue",
        ordering: "later",
        drop: [:phase, :kind, :ordering, :site, :detail]
      )

  describe "blocks_on_peer: continue" do
    test "detects mutual handle_continue cycle (Pattern 1)" do
      modules = [
        Argus.Test.Fixtures.ContinueCycleServerA,
        Argus.Test.Fixtures.ContinueCycleServerB,
        Argus.Test.Fixtures.ContinueCycleSupervisor
      ]

      # A continue cycle is blocking's call_cycle in the continue phase.
      assert {:ok, results} = Memo.analyze(modules, :blocking)
      cycles = Rows.where(results, :blocking, "call_cycle", phase: "continue")
      assert cycles != []

      # Cycle should pair the two cycle servers (lexicographic order from
      # the dedup constraint), each side at its call in handle_continue/2.
      assert Enum.any?(cycles, fn [a, b, _wa, _wb, "continue", site_a, site_b] ->
               a == "Argus.Test.Fixtures.ContinueCycleServerA" and
                 b == "Argus.Test.Fixtures.ContinueCycleServerB" and
                 site_a =~ "ContinueCycleServerA:handle_continue/2#" and
                 site_b =~ "ContinueCycleServerB:handle_continue/2#"
             end)
    end

    test "detects continue calling later-started sibling (Pattern 2)" do
      modules = [
        Argus.Test.Fixtures.ContinueLateCallerServer,
        Argus.Test.Fixtures.ContinueLateTargetServer,
        Argus.Test.Fixtures.ContinueLateSiblingSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)
      hits = continue_to_later(results)
      assert hits != []

      assert Enum.any?(hits, fn [caller, callee, sup] ->
               sup == "Argus.Test.Fixtures.ContinueLateSiblingSupervisor" and
                 caller == "Argus.Test.Fixtures.ContinueLateCallerServer" and
                 callee == "Argus.Test.Fixtures.ContinueLateTargetServer"
             end)
    end

    test "a later-sibling continue is anchored at its call, not the function's first clause" do
      modules = [
        Argus.Test.Fixtures.ContinueLateCallerServer,
        Argus.Test.Fixtures.ContinueLateTargetServer,
        Argus.Test.Fixtures.ContinueLateSiblingSupervisor
      ]

      assert {:ok, %{findings: findings}} = Memo.run_analyses(modules, analyses: [:startup])

      assert [finding] =
               Enum.filter(findings, &(&1.title == "handle_continue races a later sibling"))

      assert finding.instr != nil

      # ContinueLateCallerServer's handle_continue/2 opens with a pure
      # :warm clause; the call is in the :setup clause below it.
      {:ok, facts} = Argus.Pipeline.extract(modules)
      line = Argus.Lines.resolve(Argus.Lines.from_facts(facts), finding.instr)
      source = Path.expand("../fixtures/continue_chain_fixture.ex", __DIR__)

      assert source |> File.read!() |> String.split("\n") |> Enum.at(line - 1) =~
               "GenServer.call(Argus.Test.Fixtures.ContinueLateTargetServer, :ping)"
    end

    test "detects continue calling its own supervisor before the tree is up (Pattern 3)" do
      modules = [
        Argus.Test.Fixtures.ContinueParentCallerServer,
        Argus.Test.Fixtures.ContinueParentLaterSibling,
        Argus.Test.Fixtures.ContinueParentSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      assert [
               [
                 "Argus.Test.Fixtures.ContinueParentCallerServer",
                 sup,
                 site,
                 "Supervisor.which_children"
               ]
             ] =
               Rows.where(results, :startup, "blocks_on_peer",
                 phase: "continue",
                 kind: "parent",
                 drop: [:phase, :kind, :ordering, :sup]
               )

      assert sup == "Argus.Test.Fixtures.ContinueParentSupervisor"
      assert site =~ "handle_continue/2"
    end

    test "does NOT flag the last child calling its supervisor from continue" do
      modules = [
        Argus.Test.Fixtures.ContinueLastChildCaller,
        Argus.Test.Fixtures.ContinueParentLaterSibling,
        Argus.Test.Fixtures.ContinueLastChildSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)
      assert Rows.where(results, :startup, "blocks_on_peer", phase: "continue") == []
    end

    test "does NOT flag the safe sibling order (target started first)" do
      modules = [
        Argus.Test.Fixtures.ContinueLateCallerServer,
        Argus.Test.Fixtures.ContinueLateTargetServer,
        Argus.Test.Fixtures.SafeContinueOrderSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # The unsafe supervisor isn't in the modules list, so the only
      # supervisor visible to the analysis is the safe one. No findings.
      assert continue_to_later(results) == []
    end

    test "does NOT flag external targets in disjoint supervision trees" do
      modules = [
        Argus.Test.Fixtures.SafeContinueExternalCaller,
        Argus.Test.Fixtures.SafeContinueExternalTarget,
        Argus.Test.Fixtures.SafeContinueExternalCallerSupervisor,
        Argus.Test.Fixtures.SafeContinueExternalTargetSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)
      assert continue_to_later(results) == []

      assert {:ok, blocking} = Memo.analyze(modules, :blocking)
      assert Rows.where(blocking, :blocking, "call_cycle", phase: "continue") == []
    end

    test "does NOT flag continue using cast (cast is async)" do
      modules = [
        Argus.Test.Fixtures.SafeContinueCastCaller,
        Argus.Test.Fixtures.SafeContinueCastTarget,
        Argus.Test.Fixtures.SafeContinueCastSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)
      assert continue_to_later(results) == []
    end

    test "flags defensive try/catch as a deferral defect" do
      modules = [
        Argus.Test.Fixtures.DefensiveContinueCaller,
        Argus.Test.Fixtures.DefensiveContinueTarget,
        Argus.Test.Fixtures.DefensiveContinueSupervisor
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # The defensive variant still triggers the literal pattern 2
      # (the call IS still there in the bytecode), and the crash-loop
      # finding fires on top.
      crash_loops = Rows.where(results, :startup, "deferral_defect", kind: "continue_catch")
      assert crash_loops != []

      assert Enum.any?(crash_loops, fn [worker | _] ->
               worker == "Argus.Test.Fixtures.DefensiveContinueCaller"
             end)
    end
  end

  describe "deferral_defect: init_timeout" do
    test "an init returning {:ok, state, 0} is reported; a {:continue, _} is not" do
      assert {:ok, results} =
               Memo.analyze(
                 [
                   Argus.Test.Fixtures.TimeoutDeferredInit,
                   Argus.Test.Fixtures.ContinueDeferredInit
                 ],
                 :startup
               )

      assert [[mod, site, "0"]] =
               Rows.where(results, :startup, "deferral_defect",
                 kind: "init_timeout",
                 drop: [:kind]
               )

      assert mod == "Argus.Test.Fixtures.TimeoutDeferredInit"
      assert site =~ "TimeoutDeferredInit:init/1#"
    end

    test "the finding names the return's timeout for a reader of the source" do
      assert {:ok, %{findings: findings}} =
               Memo.run_analyses([Argus.Test.Fixtures.TimeoutDeferredInit], analyses: [:startup])

      # The return tuple has no line marker: the bytecode's line is the
      # last call's before it, and `0}` carries the anchor the last step.
      assert [%{at_source: "0}"}] =
               Enum.filter(findings, &(&1.title == "init/1 defers work with a zero timeout"))
    end
  end
end
