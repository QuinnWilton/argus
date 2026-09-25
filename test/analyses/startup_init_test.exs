defmodule Argus.Analyses.StartupInitTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # Synchronous calls from init whose place in the tree is unknown, in
  # the [mod, callee, kind] shape the rule has always produced.
  defp sync_calls(results),
    do:
      Rows.where(results, :startup, "blocks_on_peer",
        kind: "call",
        ordering: "unknown",
        drop: [:phase, :kind, :ordering, :sup, :site]
      )

  defp blocking_servers(results),
    do:
      Rows.where(results, :startup, "blocks_on_peer",
        kind: "blocking_server",
        drop: [:phase, :kind, :ordering, :sup]
      )

  defp sync_call_sites(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [Argus.Extractors.ApiCalls])
    Map.get(facts, :sync_call_site, [])
  end

  describe "blocks_on_peer: init" do
    test "detects sync call in init/1 for fixture" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)
      assert Map.has_key?(results, "blocks_on_peer")

      init_calls = sync_calls(results)
      assert init_calls != []

      # SyncInitServer's init calls WorkerA on every init.
      assert Enum.any?(init_calls, fn [mod, _callee, kind] ->
               mod == "Argus.Test.Fixtures.SyncInitServer" and kind == "unconditional"
             end)
    end

    test "supervisor management calls from init are reported" do
      skip_without_souffle()

      assert {:ok, results} =
               Memo.analyze([Argus.Test.Fixtures.StartsChildrenInInit], :startup)

      assert [[mod, "Argus.Test.Fixtures.PoolSup", site, "DynamicSupervisor.start_child"]] =
               Rows.where(results, :startup, "blocks_on_peer",
                 kind: "sup",
                 drop: [:phase, :kind, :ordering, :sup]
               )

      assert mod == "Argus.Test.Fixtures.StartsChildrenInInit"
      assert site =~ "StartsChildrenInInit:"
    end

    test "a call the tree-order argument accepts is still reported when the callee's handler blocks" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.WatcherAppTree,
        Argus.Test.Fixtures.BlockingWatcher,
        Argus.Test.Fixtures.WatchedPool
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # The Watcher is in the app tree and the pool is not: the plain
      # finding is (correctly) suppressed as a cross-supervisor call...
      refute Enum.any?(sync_calls(results), fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.WatchedPool"
             end)

      # ...and the blocking handler is what makes it a finding anyway.
      assert [[mod, dep, op_site, handler]] = blocking_servers(results)
      assert mod == "Argus.Test.Fixtures.WatchedPool"
      assert dep == "Argus.Test.Fixtures.BlockingWatcher"
      assert handler =~ "BlockingWatcher:handle_info/2"
      assert op_site =~ "BlockingWatcher:handle_info/2#"
    end

    test "the blocking handler's site is its :infinity call, not every call" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.InfiniteAppTree,
        Argus.Test.Fixtures.InfiniteWatcher,
        Argus.Test.Fixtures.InfiniteWatchedPool,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # The handler calls WorkerA with the default timeout and WorkerB
      # with :infinity; only the second call blocks it.
      assert [[_mod, _dep, op_site, _handler]] = blocking_servers(results)

      [call_b] =
        for [id, _, "Argus.Test.Fixtures.WorkerB", "-1"] <- sync_call_sites(modules), do: id

      assert op_site == call_b
    end

    test "a handler's :infinity call blocks it whatever API spells the call" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.StatemCallAppTree,
        Argus.Test.Fixtures.StatemCallWatcher,
        Argus.Test.Fixtures.StatemCallWatchedPool,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      assert [[mod, dep, op_site, _handler]] = blocking_servers(results)
      assert mod == "Argus.Test.Fixtures.StatemCallWatchedPool"
      assert dep == "Argus.Test.Fixtures.StatemCallWatcher"

      [call] =
        for [id, _, "Argus.Test.Fixtures.WorkerB", "-1"] <- sync_call_sites(modules), do: id

      assert op_site == call
    end

    test "a handler that only starts children is bounded and not reported" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.StarterAppTree,
        Argus.Test.Fixtures.StartingWatcher,
        Argus.Test.Fixtures.WatchedByStarter
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      assert blocking_servers(results) == []
    end

    test "a sibling started earlier by a GenServer-defined tree is safe" do
      skip_without_souffle()

      # The Broadway shape: the tree lives in a GenServer's init/1, the
      # producer's init calls the rate limiter, and the rate limiter is an
      # earlier child of the same rest_for_one supervisor.
      modules = [
        Argus.Test.Fixtures.TopologyServer,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      refute Enum.any?(sync_calls(results), fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.SyncInitServer"
             end)

      refute Enum.any?(sync_calls(results), fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.SyncInitServer"
             end)
    end

    test "a call behind a branch in init is reported as conditional" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.ConditionalInitServer,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      kinds =
        Map.new(sync_calls(results), fn [mod, _callee, kind] -> {mod, kind} end)

      assert kinds["Argus.Test.Fixtures.ConditionalInitServer"] == "conditional"
      assert kinds["Argus.Test.Fixtures.SyncInitServer"] == "unconditional"
    end

    test "a head match or a badmatch is no branch: its other side raises" do
      skip_without_souffle()

      modules = [Argus.Test.Fixtures.HeadMatchInitServer, Argus.Test.Fixtures.WorkerA]
      assert {:ok, results} = Memo.analyze(modules, :startup)

      assert [["Argus.Test.Fixtures.HeadMatchInitServer", _callee, "unconditional"]] =
               sync_calls(results)
    end

    test "each peer's call is judged by its own branch" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.MixedInitServer,
        Argus.Test.Fixtures.WorkerA,
        Argus.Test.Fixtures.WorkerB
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      kinds =
        for ["Argus.Test.Fixtures.MixedInitServer", callee, kind] <- sync_calls(results),
            into: %{},
            do: {callee, kind}

      # WorkerA's call is behind the branch; the unconditional call to
      # WorkerB used to make it look unconditional too.
      assert kinds["Argus.Test.Fixtures.WorkerA"] == "conditional"
      assert kinds["Argus.Test.Fixtures.WorkerB"] == "unconditional"
    end

    test "a plug's init/1 is not a process's" do
      skip_without_souffle()

      # Plug.init/1 runs in whoever builds the pipeline; only a process
      # behaviour's init/1 holds up a start.
      modules = [Argus.Test.Fixtures.PidFlow.PlugLike, Argus.Test.Fixtures.PidFlow.Hub]
      assert {:ok, results} = Memo.analyze(modules, :startup)

      refute Enum.any?(sync_calls(results), fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.PidFlow.PlugLike"
             end)
    end

    test "filters safe sibling ordering (dep starts before caller)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.SafeOrderSupervisor,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # WorkerA starts before SyncInitServer — safe, should be filtered.
      assert sync_calls(results) == []

      # The filtering relation should have the entry.
      refute Enum.any?(sync_calls(results), fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.SyncInitServer"
             end)
    end

    test "filters cross-supervisor calls (disjoint supervisor trees)" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.DisjointSupervisor,
        Argus.Test.Fixtures.CallerSupervisor,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # Disjoint supervisors — callee already running, should be filtered.
      assert sync_calls(results) == []

      refute Enum.any?(sync_calls(results), fn [mod, _, _] ->
               mod == "Argus.Test.Fixtures.SyncInitServer"
             end)
    end

    test "preserves deadlock risk when dep starts after caller" do
      skip_without_souffle()

      modules = [
        Argus.Test.Fixtures.DeadlockOrderSupervisor,
        Argus.Test.Fixtures.SyncInitServer,
        Argus.Test.Fixtures.WorkerA
      ]

      assert {:ok, results} = Memo.analyze(modules, :startup)

      # WorkerA starts AFTER SyncInitServer — NOT safe, deadlock risk:
      # one finding, the later-sibling deadlock, not also a call of
      # unknown place beside it.
      refute Enum.any?(sync_calls(results), fn [mod, callee, _kind] ->
               mod == "Argus.Test.Fixtures.SyncInitServer" and
                 callee == "Argus.Test.Fixtures.WorkerA"
             end)

      # The later-sibling row is the deadlock.
      deadlock_risks =
        Rows.where(results, :startup, "blocks_on_peer", kind: "call", ordering: "later")

      assert deadlock_risks != []

      assert Enum.any?(deadlock_risks, fn [child, _phase, dep, _kind, _ordering, sup, _site, _w] ->
               sup == "Argus.Test.Fixtures.DeadlockOrderSupervisor" and
                 child == "Argus.Test.Fixtures.SyncInitServer" and
                 dep == "Argus.Test.Fixtures.WorkerA"
             end)
    end
  end
end
