defmodule Argus.Soundness.RacesOrderTest do
  @moduledoc """
  The orderings the races model reads between processes
  (docs/design/races.md, "Which processes run a function"): a write
  another process makes is a rival only when it can land while the
  pair's process runs the pair. Every program is solved alone; each
  ordering has its quiet program and the nearest real bugs it must still
  report.
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.RacesOrder, as: O

  @ets {:warning, "Read-then-write race on an ETS key"}

  defp assert_fires(modules, {severity, title}, mfa) do
    found = fired(modules, :races)

    assert {severity, title, mfa} in found,
           "expected #{inspect({severity, title, mfa})} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  defp assert_quiet(modules) do
    assert fired(modules, :races) == []
  end

  describe "startup order: what another process writes only while it starts" do
    test "a supervisor's init/1 seeds the row before its child merges into it" do
      assert_quiet([O.ClusterState, O.ClusterSup, O.Gossip])
    end

    test "another server merging into the row once it is up" do
      assert_fires(
        [O.ClusterState, O.ClusterSup, O.Gossip, O.Peer],
        @ets,
        {O.Gossip, :handle_cast, 2}
      )
    end

    test "a worker that seeds the row in init/1 and again once it is up" do
      assert_fires(
        [O.ClusterState, O.ClusterSup, O.Gossip, O.Seeder],
        @ets,
        {O.Gossip, :handle_cast, 2}
      )
    end

    test "a task the supervisor's init/1 starts, seeding the row whenever it runs" do
      assert_fires(
        [O.ClusterState, O.ClusterSupTask, O.Gossip],
        @ets,
        {O.Gossip, :handle_cast, 2}
      )
    end
  end

  describe "handed off: a loader its starter waits for" do
    test "a loader init/1 spawns reports last, and the server queues until then" do
      assert_quiet([O.Trie])
    end

    test "a test hook that serves ungated, which nothing asks for" do
      assert_quiet([O.TrieHookUnused, O.TrieHookClient])
    end

    test "the test hook of a server its users ask through its API" do
      assert_quiet([O.TrieHookUnused])
    end

    test "vernemq's shape: a record state, served by a clause that takes any state" do
      assert_quiet([:handoff_trie, :handoff_trie_client])
      assert_quiet([:handoff_trie])
    end

    test "the test hook, asked for by an API" do
      assert_fires([O.TrieHookUsed], @ets, {O.TrieHookUsed, :bump, 2})
    end
  end

  describe "handed off: the report is the loader's last act" do
    test "a report sent before the work" do
      assert_fires([O.TrieReportEarly], @ets, {O.TrieReportEarly, :bump, 2})
    end

    test "a report sent in the middle of the work" do
      assert_fires([O.TrieReportMidway], @ets, {O.TrieReportMidway, :bump, 2})
    end

    test "a loader that stays on as a worker after reporting" do
      assert_fires([O.TrieKeepsWorking], @ets, {O.TrieKeepsWorking, :bump, 2})
    end

    test "a report the loader sends to itself" do
      assert_fires([O.TrieReportsToItself], @ets, {O.TrieReportsToItself, :bump, 2})
    end

    test "a loader started again on every reload" do
      assert_fires([O.TrieReloadLoader], @ets, {O.TrieReloadLoader, :bump, 2})
    end
  end

  describe "handed off: the report is the only message of its tag" do
    test "an API that sends the report's message too" do
      assert_fires([O.TrieAnotherReport], @ets, {O.TrieAnotherReport, :bump, 2})
    end

    test "a timer that sends the report's message" do
      assert_fires([O.TrieTimerReport], @ets, {O.TrieTimerReport, :bump, 2})
    end

    test "the server sending itself the report's message" do
      assert_fires([O.TrieSelfReport], @ets, {O.TrieSelfReport, :bump, 2})
    end
  end

  describe "handed off: the server serves only after the report" do
    test "a server that serves from the start" do
      assert_fires([O.TrieUngated], @ets, {O.TrieUngated, :bump, 2})
    end

    test "another request that opens the gate the report opens" do
      assert_fires([O.TrieOpenedEarly], @ets, {O.TrieOpenedEarly, :bump, 2})
    end

    test "a server init/1 starts already open" do
      assert_fires([O.TrieStartsReady], @ets, {O.TrieStartsReady, :bump, 2})
    end
  end

  describe "handed off: a clause no request enters never runs" do
    test "a second loader started where nothing asks" do
      assert_quiet([O.TrieDeadReloader, O.TrieReloaderClient])
    end

    test "a second loader started where an API asks" do
      assert_fires(
        [O.TrieLiveReloader, O.TrieReloaderClient],
        @ets,
        {O.TrieLiveReloader, :bump, 2}
      )
    end

    test "a request helper handed messages the program does not spell" do
      assert_fires([O.TrieWrapped, O.TrieWrappedClient], @ets, {O.TrieWrapped, :bump, 2})
    end

    test "a server whose module offers no API, asked for anything" do
      assert_fires([O.TrieNoApi], @ets, {O.TrieNoApi, :bump, 2})
    end
  end
end
