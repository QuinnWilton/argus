defmodule Argus.Soundness.RacesTest do
  @moduledoc """
  The races harm-witness model's narrowings (docs/design/races.md), each
  with the real bugs it must still report: every program is solved alone
  and must keep its finding (`Argus.Test.Soundness`).

  A check-then-act pair is a race when a rival write can land on its row
  between the read and the write — the pair itself in a second process,
  or another write of the row, named at the key it names, in a process
  other than the pair's — and what the rival and the pair's write do to
  the row together has a witness: a lost update, a clobbered count, a
  stale fill, a delete of a row made again, a claim, a take, a decision
  that does more, a guard, a minted value. The census's four
  counter-examples come first; review 2's probes are kept at the end.
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Memo
  alias Argus.Test.Soundness.Races, as: R

  @ets {:warning, "Read-then-write race on an ETS key"}
  @stale {:info, "ETS row refilled on a stale read"}
  @record {:warning, "Read-then-write race on a Mnesia record"}
  @registry {:warning, "Lookup-then-start race on a process name"}
  @publish {:warning, "ETS row published before the row it points to"}

  defp assert_fires(modules, {severity, title}, mfa) do
    found = fired(modules, :races)

    assert {severity, title, mfa} in found,
           "expected #{inspect({severity, title, mfa})} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  defp assert_quiet(modules) do
    assert fired(modules, :races) == []
  end

  describe "the census's counter-examples" do
    test "incr = set_count(count() + 1) over literal-key accessors" do
      assert_fires([R.AccessorChain], @ets, {R.AccessorChain, :put, 2})
    end

    test "a counter's reset/1 shared with a janitor in another process" do
      assert_fires([R.JanitorCounter, R.Janitor], @ets, {R.JanitorCounter, :handle_call, 3})
    end

    test "two servers each looking a name up and registering it" do
      found = fired([R.RegCache, R.RegWeb, R.RegJobs], :races)
      assert {:warning, elem(@registry, 1), {R.RegWeb, :handle_call, 3}} in found
      assert {:warning, elem(@registry, 1), {R.RegJobs, :handle_cast, 2}} in found
    end

    test "a Mnesia lease released on its owner while a transaction takes it over" do
      assert_fires([R.LeaseRelease], @record, {R.LeaseRelease, :release, 2})
    end
  end

  describe "no witness, no race: each harm still reported" do
    test "a default written blind over a row another process counts in (clobber)" do
      assert_fires([R.TripOverCounter], @ets, {R.TripOverCounter, :ensure, 1})
    end

    test "a row deleted and handed out by whoever finds it (take)" do
      assert_fires([R.PresenceTake], @ets, {R.PresenceTake, :take, 1})
    end

    test "a slot claimed on first sight, the caller told it won (claim)" do
      assert_fires([R.VerdictClaim], @ets, {R.VerdictClaim, :claim, 1})
    end

    test "a newest-wins serial both racers pass (guarded)" do
      assert_fires([R.GuardSerial], @ets, {R.GuardSerial, :put, 2})
    end

    test "a lease deleted on its owner while a takeover writes it (state delete)" do
      assert_fires([R.LeaseReleaseEts], @ets, {R.LeaseReleaseEts, :release, 2})
    end

    test "a job deleted and sent to a worker by both racers (decides more)" do
      assert_fires([R.DeleteSends], @ets, {R.DeleteSends, :dispatch, 2})
    end

    test "a copy of a Mnesia record refilled after its invalidation (stale fill)" do
      assert_fires([R.FillFromStore], @stale, {R.FillFromStore, :get, 1})
    end
  end

  describe "what a decision does besides the write" do
    test "a stop through Erlang's :supervisor, both racers stopping the pool" do
      assert_fires([R.PoolStop], @ets, {R.PoolStop, :stop, 1})
    end

    test "the same stop through Elixir's Supervisor" do
      assert_fires([R.PoolStopElixir], @ets, {R.PoolStopElixir, :stop, 1})
    end

    test "what the lookup found handed to a helper that removes hooks elsewhere" do
      assert_fires([R.ModuleStop], @ets, {R.ModuleStop, :stop_module, 1})
    end

    test "what the lookup found handed to a helper that only computes" do
      assert_quiet([R.ModuleStopCount])
    end

    test "what the lookup found handed to a helper that writes the pair's own table" do
      assert_quiet([R.ModuleStopOwnTable])
    end
  end

  describe "a pinned match's key" do
    test "the delete keyed by the row's element the match compared" do
      assert_fires([:races_pinned_delete], @ets, {:races_pinned_delete, :delete_node, 1})
    end
  end

  describe "a write is judged at the key it names" do
    test "a library's bump/1 its users call with any key, over a literal default" do
      assert_fires([R.TotalsLib], @ets, {R.TotalsLib, :ensure_total, 0})
    end

    test "keys a closure handed to Enum.each counts into" do
      assert_fires([R.TotalsEach], @ets, {R.TotalsEach, :ensure_total, 0})
    end

    test "another server counting into the literal row itself" do
      assert_fires([R.TotalsLiteral], @ets, {R.TotalsLiteral, :ensure_total, 0})
    end

    test "a setter the owner's increment calls, called with the literal by a resetter" do
      assert_fires([R.AccessorOwner, R.AccessorResetter], @ets, {R.AccessorOwner, :put, 2})
    end
  end

  describe "another process runs the rival" do
    test "a janitor server that calls reset/1 directly" do
      assert_fires(
        [R.DirectJanitor, R.DirectJanitorServer],
        @ets,
        {R.DirectJanitor, :handle_call, 3}
      )
    end

    test "a timer's apply_after runs reset/1 in a process of its own" do
      assert_fires([R.TimerReset], @ets, {R.TimerReset, :handle_call, 3})
    end

    test "a library's users call reset/1, which its own server also calls" do
      assert_fires([R.LibraryReset], @ets, {R.LibraryReset, :handle_call, 3})
    end
  end

  describe "deletes: on what the row holds, or handing the row out" do
    test "a Mnesia lease released while a dirty acquire writes it" do
      assert_fires([R.LeaseReleaseDirty], @record, {R.LeaseReleaseDirty, :release, 2})
    end

    test "a session's cleanup on its owner while the resumed session registers again" do
      assert_fires([R.SessionResume], @record, {R.SessionResume, :unregister, 2})
    end

    test "a Mnesia record deleted and handed out by whoever finds it" do
      assert_fires([R.RecordTake], @record, {R.RecordTake, :take, 1})
    end
  end

  describe "a stale fill needs a source that can change" do
    test "a cache filled from a server's answer and invalidated" do
      found = fired([R.FillViaServer], :races)
      assert Enum.any?(found, &match?({_, _, {R.FillViaServer, :get, 1}}, &1)), inspect(found)
    end

    test "a cache filled by a helper that reads a file, and invalidated" do
      assert_fires([R.FillViaHelper], @stale, {R.FillViaHelper, :get, 1})
    end

    test "a fill from Mnesia and an update that writes the cache itself" do
      assert_fires([R.FillOverUpdate], @stale, {R.FillOverUpdate, :get, 1})
    end
  end

  describe "a second claimant of a name" do
    test "a server's first use and its library's ensure/0" do
      assert_fires([R.RegCache, R.RegServer], @registry, {R.RegServer, :handle_call, 3})
    end

    test "a server and a task it starts per message" do
      assert_fires([R.RegCache, R.RegTaskClaim], @registry, {R.RegTaskClaim, :handle_cast, 2})
    end
  end

  describe "a one-table map: the reader takes the value from the table" do
    test "inline" do
      assert_fires([R.OneTableTaken], @publish, {R.OneTableTaken, :register, 1})
    end

    test "through a helper handed the id" do
      assert_fires([R.OneTableHelper], @publish, {R.OneTableHelper, :register, 1})
    end

    test "matched out of lookup/2" do
      assert_fires([R.OneTableLookup], @publish, {R.OneTableLookup, :register, 1})
    end
  end

  describe "the quiet controls" do
    test "a counter only its own process writes" do
      assert_quiet([R.CounterSelf])
    end

    test "a default both racers write alike, nothing else writing the row" do
      assert_quiet([R.DefaultOnly])
    end

    test "a refill that is a function of the key, invalidated" do
      assert_quiet([R.PureFill])
    end
  end

  # Review 2's probes: a stage transition chosen by the read.
  @probes [
    Probe.R2.G7.Advance,
    Probe.R2.G7.MnesiaAdvance,
    Probe.R2.G7.ToggleHelper,
    S2c.Races.AdvanceInline,
    S2c.Races.AdvanceTwoDeep,
    S2c.Races.Stages,
    S2c.Races.AdvanceRemote,
    S2c.Races.AdvanceVar
  ]

  @probe_fires [
    {:warning, "Read-then-write race on an ETS key", {Probe.R2.G7.Advance, :advance, 1}},
    {:warning, "Read-then-write race on an ETS key", {Probe.R2.G7.ToggleHelper, :flip, 1}},
    {:warning, "Read-then-write race on an ETS key", {S2c.Races.AdvanceInline, :advance, 1}},
    {:warning, "Read-then-write race on an ETS key", {S2c.Races.AdvanceRemote, :advance, 1}},
    {:warning, "Read-then-write race on an ETS key", {S2c.Races.AdvanceVar, :advance, 1}}
  ]

  describe "review 2's probes" do
    setup do
      {:ok, res} = Memo.run_analyses(@probes, analyses: [:races])
      %{found: MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa})}
    end

    for {severity, title, mfa} <- @probe_fires do
      test "#{inspect(mfa)} keeps #{severity}: #{title}", %{found: found} do
        assert {unquote(severity), unquote(title), unquote(Macro.escape(mfa))} in found
      end
    end
  end
end
