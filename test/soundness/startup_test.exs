defmodule Argus.Soundness.StartupTest do
  @moduledoc """
  startup bugs a suppression once silenced, and their adversarial
  neighbours: each program is solved alone and must keep its finding at
  the severity the rule gave it before the suppression
  (`Argus.Test.Soundness`), or the one the rubric gives it where the
  suppression's parent misread the phase.
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Startup, as: S

  @before_dep "Child starts before its dependency"

  describe "a task init/1 starts runs in the startup window (review 2, item 11)" do
    test "a started task's cast to a later sibling" do
      assert {:warning, @before_dep, {S.TaskCast.Sup, :init, 1}} in fired(
               [S.TaskCast.Announcer, S.TaskCast.Registry, S.TaskCast.Sup],
               :startup
             )
    end

    test "an awaited task's cast to a later sibling" do
      mods = [S.AwaitedTaskCast.Announcer, S.AwaitedTaskCast.Registry, S.AwaitedTaskCast.Sup]
      assert {:warning, @before_dep, {S.AwaitedTaskCast.Sup, :init, 1}} in fired(mods, :startup)
    end

    test "a bare spawn's cast, from a helper init/1 calls" do
      mods = [S.SpawnCast.Announcer, S.SpawnCast.Registry, S.SpawnCast.Sup]
      assert {:warning, @before_dep, {S.SpawnCast.Sup, :init, 1}} in fired(mods, :startup)
    end
  end

  describe "the ack ends the start's hold, not the startup window (review 2, item 12)" do
    # The parent reported the post-ack call as "Startup deadlock" (error);
    # after the ack the supervisor is released, so it is the race a
    # handle_continue's call is (the rubric's timing window, :warning).
    test "a call to a later sibling after the ack races its start" do
      mods = [S.AckEarly.Cache, S.AckEarly.Config, S.AckEarly.Sup]
      assert {:warning, @before_dep, {S.AckEarly.Sup, :init, 1}} in fired(mods, :startup)
    end

    test "a call and a cast to later siblings in a helper after the ack" do
      mods = [S.AckHelpers.Cache, S.AckHelpers.Config, S.AckHelpers.Events, S.AckHelpers.Sup]
      found = fired(mods, :startup)
      assert Enum.count(found, &(&1 == {:warning, @before_dep, {S.AckHelpers.Sup, :init, 1}})) == 2
    end

    # The parent reported it as init/1's supervisor call (:info); after
    # the ack it is handle_continue's Pattern 3 (:warning).
    test "a call on its own supervisor after the ack" do
      mods = [S.AckAsksSup.Worker, S.AckAsksSup.Later, S.AckAsksSup.Sup]

      assert {:warning, "init/1 calls its own supervisor after acknowledging its start",
              {S.AckAsksSup.Worker, :init, 1}} in fired(mods, :startup)
    end

    test "the same call from a helper after the ack" do
      mods = [S.AckSupHelper.Worker, S.AckSupHelper.Later, S.AckSupHelper.Sup]

      assert {:warning, "init/1 calls its own supervisor after acknowledging its start",
              {S.AckSupHelper.Worker, :siblings, 0}} in fired(mods, :startup)
    end

    test "the last child's call on its supervisor after the ack is quiet" do
      mods = [S.AckLastAsksSup.Earlier, S.AckLastAsksSup.Worker, S.AckLastAsksSup.Sup]
      assert fired(mods, :startup) == []
    end

    test "a connect with no retry after the ack" do
      assert {:warning, "init/1 connects with no reconnect path", {S.AckConnect, :init, 1}} in fired(
               [S.AckConnect],
               :startup
             )
    end

    test "the same connect in a helper after the ack" do
      assert {:warning, "init/1 connects with no reconnect path", {S.AckConnectHelper, :init, 1}} in fired(
               [S.AckConnectHelper],
               :startup
             )
    end
  end
end
