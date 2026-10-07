defmodule Argus.Analyses.BlockingCycleTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.{CallCycle, PidFlow}
  alias Argus.Test.Memo

  # A "call" cycle between the two modules, in either order.
  defp cycle?(results, a, b) do
    pair = Enum.sort([inspect(a), inspect(b)])

    Enum.any?(results["call_cycle"], fn [x, y, _, _, phase | _] ->
      phase == "call" and Enum.sort([x, y]) == pair
    end)
  end

  describe "call_cycle.dl" do
    test "detects mutual sync-call cycle between fixture GenServers" do
      modules = [
        Argus.Test.Fixtures.CycleServerA,
        Argus.Test.Fixtures.CycleServerB
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)
      assert Map.has_key?(results, "call_cycle")
      assert Map.has_key?(results, "call_cycle_path")

      cycles = results["call_cycle"]
      assert cycles != []

      # The two fixture modules should form a cycle.
      cycle_mods = cycles |> List.flatten() |> Enum.sort()

      assert "Argus.Test.Fixtures.CycleServerA" in cycle_mods
      assert "Argus.Test.Fixtures.CycleServerB" in cycle_mods
    end

    test "a cycle between servers that hold each other only by pid" do
      # A starts B with self(); each keeps the other's pid in its state and
      # calls it, so both GenServer.call targets are "dynamic" to sync_call.
      # Process points-to (clientlib/processes.dl) follows the pids back.
      a = Argus.Test.Fixtures.PidFlow.CycleA
      b = Argus.Test.Fixtures.PidFlow.CycleB

      assert {:ok, results} = Memo.analyze([a, b], :blocking)

      assert Enum.any?(results["call_cycle"], fn [x, y | _] ->
               Enum.sort([x, y]) == Enum.sort([inspect(a), inspect(b)])
             end)

      # B never names A, and both handle both tags: the edge back to A is
      # the points-to analysis's alone, not the tag attribution's.
      assert Enum.any?(results["call_cycle_path"], fn
               [_, _, from, to, _, "static", _] -> from == inspect(b) and to == inspect(a)
               _ -> false
             end)
    end

    test "a cycle through a pid a subscriber sent in a message" do
      # The listener casts its own pid to the hub, which keeps it in its
      # state and calls it; the listener calls the hub back by name.
      hub = Argus.Test.Fixtures.PidFlow.Hub
      listener = Argus.Test.Fixtures.PidFlow.Listener

      assert {:ok, results} = Memo.analyze([hub, listener], :blocking)

      assert Enum.any?(results["call_cycle_path"], fn
               [_, _, from, to, _, "static", _] ->
                 from == inspect(hub) and to == inspect(listener)

               _ ->
                 false
             end)
    end

    test "a state holding two pids is not one bag of them" do
      # Front keeps Back and Side in one state map and calls only Back;
      # Side calls Front by name. With the state a bag, Front "called" Side
      # too and the pair looked like a deadlock, and C → A → B like a chain
      # of ten hops.
      mods = for m <- [Front, Back, Side], do: Module.concat(Argus.Test.Fixtures.PidFlow, m)
      assert {:ok, results} = Memo.analyze(mods, :blocking)

      assert results["call_cycle"] == []

      # Side → Front → Back is the one real chain.
      for [_from, _to, "chain", depth | _] <- results["call_chain"] do
        assert depth == "2", "call chain depth #{depth}"
      end
    end

    test "a helper shared by two servers does not join their peers" do
      # UserA and UserB each call a private peer through SafeCall; TargetB
      # calls UserA back by name. With the helper's parameter every
      # caller's pid, UserA "called" TargetB too: a false cycle.
      mods =
        for m <- [SafeCall, UserA, UserB, TargetA, TargetB],
            do: Module.concat(Argus.Test.Fixtures.PidFlow, m)

      assert {:ok, results} = Memo.analyze(mods, :blocking)
      assert results["call_cycle"] == []
    end

    test "a name each caller hands a shared helper is that caller's target alone" do
      # NamedUserA and NamedUserB call their own targets through NamedCall;
      # NamedTargetB calls NamedUserA back by name. With the helper's
      # parameter every caller's name, NamedUserA "called" NamedTargetB.
      mods =
        for m <- [NamedCall, NamedUserA, NamedUserB, NamedTargetA, NamedTargetB],
            do: Module.concat(Argus.Test.Fixtures.PidFlow, m)

      assert {:ok, results} = Memo.analyze(mods, :blocking)
      assert results["call_cycle"] == []
    end

    test "a cycle through a helper both servers call each other by" do
      mods =
        for m <- [NamedCall, NamedPeerA, NamedPeerB],
            do: Module.concat(Argus.Test.Fixtures.PidFlow, m)

      assert {:ok, results} = Memo.analyze(mods, :blocking)
      assert cycle?(results, PidFlow.NamedPeerA, PidFlow.NamedPeerB)
    end

    test "thin wrappers over one server module do not call each other" do
      # Plausible's Event and Session write buffers: each names an instance
      # of WriteBuffer after itself and forwards to its API. No process
      # calls another; the wrappers run no process at all.
      mods =
        for m <- [WriteBuffer, EventBuffer, SessionBuffer, Buffers],
            do: Module.concat(CallCycle, m)

      assert {:ok, results} = Memo.analyze(mods, :blocking)
      assert results["call_cycle"] == []
    end

    test "a client function in a server module is not that server waiting" do
      # Producer.produce/1 calls Batcher, but it runs in its caller; only
      # Batcher's process calls Producer's (klife's Producer and Batcher).
      assert {:ok, results} = Memo.analyze([CallCycle.Producer, CallCycle.Batcher], :blocking)
      assert results["call_cycle"] == []
    end

    test "a task the server waits for holds it in the cycle" do
      assert {:ok, results} = Memo.analyze([CallCycle.Awaiter, CallCycle.Awaited], :blocking)
      assert cycle?(results, CallCycle.Awaiter, CallCycle.Awaited)
    end

    test "a wait an unnamed channel makes only while it joins does not close a cycle" do
      # LiveView's upload channel registers with the view from join/3,
      # handing it self(); the view answers at once and calls the channel
      # later, through the pid it kept. Nothing else can reach the channel
      # while it joins.
      assert {:ok, results} = Memo.analyze([CallCycle.View, CallCycle.UploadChannel], :blocking)
      assert results["call_cycle"] == []
    end

    test "a wait an unnamed server makes only in init/1 does not close a cycle" do
      assert {:ok, results} = Memo.analyze([CallCycle.Manager, CallCycle.Worker], :blocking)
      assert results["call_cycle"] == []
    end

    test "a server named while its init/1 waits can be called in it" do
      # NamedManager calls NamedWorker by name, which it holds from the
      # moment the start registers it: both can wait at once.
      assert {:ok, results} =
               Memo.analyze([CallCycle.NamedManager, CallCycle.NamedWorker], :blocking)

      assert cycle?(results, CallCycle.NamedManager, CallCycle.NamedWorker)
    end

    test "a peer that answers the start's request by calling back is a cycle" do
      # Greeter's :hello clause calls the Joiner whose init/1 is waiting
      # for that very reply: the start deadlocks every time.
      assert {:ok, results} = Memo.analyze([CallCycle.Greeter, CallCycle.Joiner], :blocking)
      assert cycle?(results, CallCycle.Greeter, CallCycle.Joiner)
    end

    test "each direction points at the call into the other's client API" do
      alias Argus.Test.Fixtures.CallCycle.{ExtensionsHub, HubSocket}

      assert {:ok, results} = Memo.analyze([ExtensionsHub, HubSocket], :blocking)

      rows = results["call_cycle"]
      assert rows != []

      # The detach closure's side is its HubSocket.push/1 call, not the
      # closure's first line, and the join clause's side its
      # ExtensionsHub.offer/1: a call into the other's client API, which
      # left the site empty before. (handle_cast/2 itself, which only
      # builds the closure, keeps an empty site.)
      sites =
        for [_, _, witness_a, witness_b, "call", site_a, site_b] <- rows,
            {witness, site} <- [{witness_a, site_a}, {witness_b, site_b}],
            site != "",
            do: {witness, site}

      assert {closure, push} =
               Enum.find(sites, fn {w, _} -> String.contains?(w, "-handle_cast/2-fun-") end)

      assert {:ok, %{func: "-handle_cast/2-fun-0-"}} = Argus.InstrId.parse(push)
      assert closure =~ "ExtensionsHub"
      assert Enum.any?(sites, fn {w, _} -> String.ends_with?(w, "HubSocket:handle_info/2") end)
    end

    test "runs without error on module with no cycles" do
      assert {:ok, results} = Memo.analyze([:maps], :blocking)
      assert Map.has_key?(results, "call_cycle")
    end

    test "detects gen_event sync_notify cycles via the gen_event extractor" do
      # Two :gen_event handler modules whose handle_event clauses
      # sync_notify each other. With the gen_event extractor wired into
      # call_cycle's extractor list, the resulting sync_call facts feed
      # call_cycle's existing rules and the cycle is detected — the
      # whole point of reusing sync_call as the relation.
      modules = [
        Argus.Test.Fixtures.GenEventCycleA,
        Argus.Test.Fixtures.GenEventCycleB
      ]

      assert {:ok, results} = Memo.analyze(modules, :blocking)
      cycles = results["call_cycle"]
      assert cycles != []

      cycle_mods = cycles |> List.flatten() |> Enum.sort()
      assert "Argus.Test.Fixtures.GenEventCycleA" in cycle_mods
      assert "Argus.Test.Fixtures.GenEventCycleB" in cycle_mods
    end
  end
end
