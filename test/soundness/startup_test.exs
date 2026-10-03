defmodule Argus.Soundness.StartupTest do
  @moduledoc """
  startup bugs a suppression once silenced, and their adversarial
  neighbours: each program is solved alone and must keep its finding at
  the severity the rule gave it before the suppression
  (`Argus.Test.Soundness`), or the one the rubric gives it where the
  suppression's parent misread the phase.
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Census.Startup, as: C
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

      assert Enum.count(found, &(&1 == {:warning, @before_dep, {S.AckHelpers.Sup, :init, 1}})) ==
               2
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

  describe "a later child the extractor cannot read keeps the worker from being last (review 2, item 20)" do
    @continue_parent "handle_continue calls its own supervisor"

    for {name, group} <- [
          {"a later child written with Supervisor.child_spec/2", ContSpec},
          {"a child list appended from config", ContConfig},
          {"a child list a local helper appends config to", ContHelper},
          {"later children from an Enum.map", ContMapped}
        ] do
      @group Module.concat(S, group)
      test name do
        mods =
          for m <- [Worker, Later, Shard, Sup],
              Code.ensure_loaded?(Module.concat(@group, m)),
              do: Module.concat(@group, m)

        assert {:warning, @continue_parent, {Module.concat(@group, Worker), :handle_continue, 2}} in fired(
                 mods,
                 :startup
               )
      end
    end

    test "a deadlock on a later sibling written with Supervisor.child_spec/2" do
      mods = [S.SpecOrder.Worker, S.SpecOrder.Later, S.SpecOrder.Sup]

      assert {:error, "Startup deadlock: init waits on a later sibling",
              {S.SpecOrder.Worker, :init, 1}} in fired(
               mods,
               :startup
             )
    end

    test "a closed list's last child is quiet" do
      assert fired([S.ContLast.Worker, S.ContLast.Earlier, S.ContLast.Sup], :startup) == []
    end
  end

  # Suppression counterexamples for startup, over
  # one fixture set (test/fixtures/soundness/startup_census.ex).
  @census [
    C.Config,
    C.Cache,
    C.App,
    C.SizedCache,
    C.SizedApp,
    C.EarlyConfigCache,
    C.EarlyApp,
    C.Settings,
    C.TaskCache,
    C.HelperTaskCache,
    C.FireAndForgetCache,
    C.TaskSup
  ]

  @deadlock "Startup deadlock: init waits on a later sibling"

  defp census_deadlock?(mod), do: {:error, @deadlock, {mod, :init, 1}} in fired(@census, :startup)

  # census: awaited-task
  # A task init/1 awaits was not init/1's wait: reaches_sync_dep did not
  # step into it.
  describe "census hole: a later sibling a task init/1 awaits calls" do
    for mod <- [C.TaskCache, C.HelperTaskCache] do
      test "#{inspect(mod)}: init/1 waits on the later sibling through its task" do
        assert census_deadlock?(unquote(mod))
      end
    end

    test "a task init/1 does not await is the startup window's warning" do
      refute census_deadlock?(C.FireAndForgetCache)
      assert {:warning, @before_dep, {C.TaskSup, :init, 1}} in fired(@census, :startup)
    end
  end

  # census: after-tree
  # Two supervision trees were taken as running for each other by being
  # two, though the start function starts the peer after the tree.
  describe "census hole: a peer the start function starts after the tree" do
    for mod <- [C.Cache, C.SizedCache] do
      test "#{inspect(mod)}: init/1 waits on a process started after its tree" do
        assert census_deadlock?(unquote(mod))
      end
    end

    test "a peer started before the tree is quiet" do
      refute Enum.any?(fired(@census, :startup), &match?({_, _, {C.EarlyConfigCache, _, _}}, &1))
    end
  end

  describe "a process that declares no behaviour (started_as)" do
    # A start that names a module the callback module of a behaviour is a
    # witness of it as `-behaviour` is (behaviours.dl, behaves_as): OTP's
    # inet_db and pg, and ejabberd's ejabberd_sql_sup, declare none.
    @deadlock "Startup deadlock: init waits on a later sibling"

    test "a gen_server that starts itself: its init/1 waits on a later sibling" do
      assert {:error, @deadlock, {:bless_server, :init, 1}} in fired(
               [:bless_sup, :bless_server, :bless_later],
               :startup
             )
    end

    test "a supervisor that starts itself: its tree orders the children" do
      assert {:error, @deadlock, {:bless_caller, :init, 1}} in fired(
               [:bless_bare_sup, :bless_caller, :bless_callee],
               :startup
             )
    end

    test "an init/1 nothing starts runs in its caller, and is quiet" do
      fired = fired([:bless_sup, :bless_server, :bless_later, :bless_plain], :startup)
      refute Enum.any?(fired, &match?({_, _, {:bless_plain, _, _}}, &1))
    end
  end
end
