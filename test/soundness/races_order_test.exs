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
end
