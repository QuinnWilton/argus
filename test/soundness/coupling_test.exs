defmodule Argus.Soundness.CouplingTest do
  @moduledoc """
  "Coupled children under one_for_one" is reported for what a sibling's restart loses
  (clientlib/restart_state.dl, docs/analyses/coupling.md#restart-isolation): a
  registration a child makes once, when it starts, that its sibling keeps. It is not
  reported for a call made on each use.

  The model narrows the class in two ways. Each narrowing has adversarial
  shapes of the nearest real bug that must still fire:

  - **Only once code counts.** A registration made from init/1
    (`CastJoiner`, `DictUser`, `restart_record_user`), from
    handle_continue/2 (`ContinueJoiner`), from a helper init/1 calls
    (`HookUser`) or from a fun init/1 hands to `Enum.each/2` (`EachUser`)
    still fires, and so does one made through a client API that takes
    the server as an argument (`ServerArgListener`, `ServerArgCastJoiner`:
    the request is the keeper's by the tag its own handler takes), also
    from a helper of the caller's own (`HelperListener`). A cast made
    directly at a site of the once phase is a registration as a call there
    is: in the handle_continue/2 clause init/1 continues to
    (`ContinueCastJoiner`, `restart_cast_cont_user`) and in the
    handle_info/2 clause for a message only init/1 sends
    (`restart_cast_info_user`). A call made on each use (`Relay`,
    `ServerArgPublisher`) does not fire, nor a cast made on each use
    (`PerUseCaster`) or from a continue only a periodic tick reaches
    (`TickCastJoiner`), and neither does a request whose tag the target's
    handler does not take (`ProxyUser`, `CastProxyUser`).
  - **Only what the sibling keeps counts.** A map state (`CastKeeper`),
    a record state with no monitor (`restart_record_keeper`), a monitor
    (`ContinueKeeper`), an ETS row (`HookKeeper`), the process dictionary
    (`DictKeeper`) and a flag a bare cast sets to what init/1 does not
    (`FlagKeeper`) are all kept, and so is a state a library call
    computes (`ComputedKeeper`, `Map.update/4` as MongooseIM's gen_hook's
    `maps:put/3`). So is a registering clause beside a resetting one
    (`MixedKeeper`), and the writing clause of a keeper whose read clause
    keeps nothing (`ClauseKeeper`). A library the keeper hands the
    request to may keep it (`BrokerClient`): that fires at `:info`, as
    inferred evidence. A field reset to its initial value
    (`CacheKeeper`, `restart_reset_keeper`) and a read (`ConfigKeeper`,
    `ClauseReader`'s clause) keep nothing, so they do not fire.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Fixtures.Restart
  alias Argus.Test.Memo

  @title "Coupled children under one_for_one"
  @source Path.expand("../fixtures/soundness/coupling_soundness.ex", __DIR__)
  @erl_cont Path.expand("../fixtures/erl/restart_cast_cont_user.erl", __DIR__)
  @erl_info Path.expand("../fixtures/erl/restart_cast_info_user.erl", __DIR__)

  @fixtures [
    Restart.CastSup,
    Restart.CastKeeper,
    Restart.CastJoiner,
    Restart.ContinueSup,
    Restart.ContinueKeeper,
    Restart.ContinueJoiner,
    Restart.HookSup,
    Restart.HookKeeper,
    Restart.HookUser,
    Restart.EachSup,
    Restart.EachKeeper,
    Restart.EachUser,
    Restart.HandedSup,
    Restart.BrokerClient,
    Restart.Subscriber,
    Restart.DictSup,
    Restart.DictKeeper,
    Restart.DictUser,
    Restart.FlagSup,
    Restart.FlagKeeper,
    Restart.FlagUser,
    Restart.MixedSup,
    Restart.MixedKeeper,
    Restart.MixedUser,
    Restart.PerUseSup,
    Restart.Store,
    Restart.Relay,
    Restart.ResetSup,
    Restart.CacheKeeper,
    Restart.CacheUser,
    Restart.ReadSup,
    Restart.ConfigKeeper,
    Restart.ConfigUser,
    Restart.ClauseSup,
    Restart.ClauseKeeper,
    Restart.ClauseReader,
    Restart.ClauseWriter,
    Restart.ComputedSup,
    Restart.ComputedKeeper,
    Restart.ComputedUser,
    :restart_record_sup,
    :restart_record_keeper,
    :restart_record_user,
    :restart_reset_sup,
    :restart_reset_keeper,
    :restart_reset_user,
    Restart.ServerArgSup,
    Restart.ServerArgKeeper,
    Restart.ServerArgListener,
    Restart.ServerArgPublisher,
    Restart.ServerArgCastSup,
    Restart.ServerArgCastKeeper,
    Restart.ServerArgCastJoiner,
    Restart.ProxySup,
    Restart.Proxy,
    Restart.ProxyUser,
    Restart.HelperListenSup,
    Restart.HelperListenKeeper,
    Restart.HelperListener,
    Restart.ContinueCastSup,
    Restart.ContinueCastKeeper,
    Restart.ContinueCastJoiner,
    :restart_cast_keeper,
    :restart_cast_cont_sup,
    :restart_cast_cont_user,
    :restart_cast_info_sup,
    :restart_cast_info_user,
    Restart.TickCastSup,
    Restart.TickCastKeeper,
    Restart.TickCastJoiner,
    Restart.PerUseCastSup,
    Restart.PerUseCastKeeper,
    Restart.PerUseCaster,
    Restart.CastProxySup,
    Restart.CastProxy,
    Restart.CastProxyUser
  ]

  setup_all do
    %{fired: fired(@fixtures, :coupling)}
  end

  defp coupled(fired, sup), do: for({sev, @title, {^sup, :init, 1}} <- fired, do: sev)

  for sup <- [
        Restart.CastSup,
        Restart.ContinueSup,
        Restart.HookSup,
        Restart.EachSup,
        Restart.DictSup,
        Restart.FlagSup,
        Restart.MixedSup,
        Restart.ComputedSup,
        :restart_record_sup,
        Restart.ServerArgSup,
        Restart.ServerArgCastSup,
        Restart.HelperListenSup,
        Restart.ContinueCastSup,
        :restart_cast_cont_sup,
        :restart_cast_info_sup
      ] do
    test "#{inspect(sup)}: a registration its sibling keeps is reported", %{fired: fired} do
      assert coupled(fired, unquote(sup)) == [:warning]
    end
  end

  test "a registration the keeper hands to a library is reported, as inferred", %{fired: fired} do
    assert coupled(fired, Restart.HandedSup) == [:info]
  end

  for sup <- [
        Restart.PerUseSup,
        Restart.ResetSup,
        Restart.ReadSup,
        :restart_reset_sup,
        Restart.ProxySup,
        Restart.TickCastSup,
        Restart.PerUseCastSup,
        Restart.CastProxySup
      ] do
    test "#{inspect(sup)}: nothing its sibling keeps, no coupling", %{fired: fired} do
      assert coupled(fired, unquote(sup)) == []
    end
  end

  # One keeper, a reader and a writer under one supervisor: one finding
  # (the writer's), since the reader's clause keeps nothing.
  test "the clause a request enters decides, not the handler's other clauses", %{fired: fired} do
    assert coupled(fired, Restart.ClauseSup) == [:warning]

    assert {:ok, results} = Memo.analyze(@fixtures, :coupling)

    callers =
      for [sup, caller, _callee, "restart_isolation" | _] <- results["sibling_dependency"],
          sup == inspect(Restart.ClauseSup),
          uniq: true,
          do: caller

    assert callers == [inspect(Restart.ClauseWriter)]
  end

  # A client API that takes the server (eusapia's and Oban's Notifier):
  # the listener's registration from handle_continue/2 is held, the
  # publisher's per-use notify through the same API is not.
  test "a request through the keeper's own API resolves by its tag", %{fired: fired} do
    assert coupled(fired, Restart.ServerArgSup) == [:warning]

    assert {:ok, results} = Memo.analyze(@fixtures, :coupling)

    callers =
      for [sup, caller, _callee, "restart_isolation" | _] <- results["sibling_dependency"],
          sup == inspect(Restart.ServerArgSup),
          uniq: true,
          do: caller

    assert callers == [inspect(Restart.ServerArgListener)]
  end

  # Where the finding shows the registration: the step of the caller's
  # once phase that makes it or leads to it, which is the caller's own
  # code. Not the keeper's client API the step calls (depot's and
  # eusapia's Sonar, calling `Notifier.listen(server, channel)` from
  # handle_continue/2), and not a helper of the caller's below the step.
  describe "the registration's frame" do
    for {sup, caller, source, text} <- [
          {Restart.ServerArgSup, Restart.ServerArgListener, @source,
           ":ok = ServerArgKeeper.listen(s.keeper, :health)"},
          {Restart.ContinueSup, Restart.ContinueJoiner, @source,
           ":ok = Argus.Test.Fixtures.Restart.ContinueKeeper.join(self())"},
          {Restart.HelperListenSup, Restart.HelperListener, @source, ":ok = listen_on(s.keeper)"},
          {Restart.HookSup, Restart.HookUser, @source, "    register_hooks()"},
          # A cast the phase makes itself is its own step: the cast.
          {Restart.ContinueCastSup, Restart.ContinueCastJoiner, @source,
           "GenServer.cast(ContinueCastKeeper, {:join, self()})"},
          {:restart_cast_cont_sup, :restart_cast_cont_user, @erl_cont,
           "gen_server:cast(restart_cast_keeper, {join, self()})"},
          {:restart_cast_info_sup, :restart_cast_info_user, @erl_info,
           "gen_server:cast(restart_cast_keeper, {join, self()})"}
        ] do
      test "#{inspect(caller)}: at the caller's own step" do
        sup = unquote(sup)
        caller = unquote(caller)

        assert {:ok, %{findings: findings}} =
                 Memo.run_analyses(@fixtures, analyses: [:coupling])

        assert [finding] =
                 Enum.filter(findings, &(&1.title == @title and &1.mfa == {sup, :init, 1}))

        frame =
          Enum.find(finding.related, &(&1.label == "registers with the sibling here")) ||
            flunk("no registration frame in #{inspect(finding.related)}")

        assert frame.module == caller
        assert frame.instr != nil, "the frame is a function's head, not the step's call"
        assert frame_line(frame) == fixture_line(unquote(source), unquote(text))
      end
    end
  end

  defp frame_line(frame) do
    {:ok, facts} = Argus.Pipeline.extract([frame.module])
    Argus.Lines.resolve(Argus.Lines.from_facts(facts), frame.instr)
  end

  # The fixture's line holding `text`, found by the text so the fixture
  # can move freely.
  defp fixture_line(source, text) do
    source
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, text))
    |> Kernel.+(1)
  end

  # Suppression counterexample: the
  # restart a DynamicSupervisor start gives its child is the spec's it
  # hands over (clientlib/supervision.dl's dynamic_restart), not the
  # module's own child_spec/1's, which a map spec never calls.
  describe "census hole: the restart the start gives" do
    alias Argus.Test.Soundness.Census.Coupling, as: C

    @census [
      C.Conn,
      C.MapManager,
      C.HelperSpecManager,
      C.PermanentMapManager,
      C.ShorthandManager,
      C.TemporaryMapManager
    ]

    @dual "Two restart authorities for the same child"

    for mod <- [C.MapManager, C.HelperSpecManager, C.PermanentMapManager] do
      test "#{inspect(mod)}: a permanent spec over a temporary module has two authorities" do
        assert {:warning, @dual, {unquote(mod), :start_conn, 1}} in fired(@census, :coupling)
      end
    end

    test "a shorthand of the temporary module and a temporary map are quiet" do
      found = fired(@census, :coupling)

      for mod <- [C.ShorthandManager, C.TemporaryMapManager] do
        refute Enum.any?(found, &match?({_, @dual, {^mod, _, _}}, &1)), inspect(mod)
      end
    end
  end
end
