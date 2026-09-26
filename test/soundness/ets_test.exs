defmodule Argus.Soundness.EtsTest do
  @moduledoc """
  Review 2's probes and their adversarial neighbours for the ets analysis:
  real bugs a suppression once silenced, each pinned at the severity the
  rule gives it without the suppression (round sound2c). The ETS rows
  round (etsrows) adds the neighbours of its two quietings of "read while
  its owner may be restarting": a read cannot reach a table its operand
  cannot name, and an application's root supervisor restarts only with
  its application.
  """
  use ExUnit.Case, async: true

  alias Argus.Test.Memo

  @modules [
    S2c.Ets.Job,
    S2c.Ets.Plugish,
    Probe.R2.G5.WarmRatesJob,
    Probe.R2.G5.Rates,
    Probe.R2.G7.KeeperServer,
    Probe.R2.G7.KeeperTask,
    Probe.R2.G5.WhereisClauses,
    Probe.R2.G5.WhereisNoted,
    Probe.R2.G7.Metrics,
    Probe.R2.G7.MetricsServer,
    S2c.Ets.PlugOwner,
    S2c.Ets.Strategy,
    S2c.Ets.StrategyNamed,
    S2c.Ets.StrategyKept,
    S2c.Ets.StrategyReturned,
    S2c.Ets.RatesHelper,
    S2c.Ets.HelperJob,
    S2c.Ets.KeeperMfa,
    S2c.Ets.KeeperAsync,
    S2c.Ets.KeeperHanded,
    S2c.Ets.KeeperSelfRead,
    S2c.Ets.WhereisInverted,
    S2c.Ets.WhereisOther,
    S2c.Ets.WhereisStored,
    S2c.Ets.WhereisGuarded,
    S2c.Ets.Counters,
    S2c.Ets.CountersServer,
    S2c.Ets.CountersClient,
    S2c.Ets.Gauges,
    S2c.Ets.GaugesServer,
    S2c.Own.AgentStart,
    S2c.Own.ProcLib,
    S2c.Own.KeeperBeside,
    S2c.Own.Sup,
    S2c.Own2.AgentStart,
    :probe_r2_g5_bridge,
    Rows.Ets.NamedServer,
    Rows.Ets.ScratchSameAtom,
    Rows.Ets.StateTableReader,
    Rows.Ets.OptionNamed,
    Rows.Ets.HelperNamed,
    Rows.Ets.HelperScratch,
    Rows.Ets.UnnamedOwner,
    Rows.Ets.OwnScratchReader,
    Rows.Ets.ScratchAtomServer,
    Rows.Ets.ConfiguredOptions,
    :rows_snapshot_reader,
    :root_app,
    :root_app_sup,
    :dual_app,
    :dual_sup,
    :outer_sup,
    :fake_app,
    :fake_root_sup,
    :branch_sup,
    :worker_app,
    :worker_owner,
    :rows_root_app,
    :rows_root_sup,
    :rows_root_child,
    :rows_root_tabs
  ]

  setup_all do
    {:ok, res} = Memo.run_analyses(@modules, analyses: [:ets])
    {:ok, rows} = Memo.analyze(@modules, :ets)

    %{
      found: MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa}),
      reads: rows["ets_read_outside_owner"]
    }
  end

  @fires [
    {:warning, "ETS table dies with its owner", {Probe.R2.G5.WarmRatesJob, :perform, 1}},
    {:warning, "ETS table dies with its owner", {:probe_r2_g5_bridge, :init, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {:probe_r2_g5_bridge, :lookup, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {Probe.R2.G5.Rates, :lookup, 1}},
    {:warning, "ETS table dies with its owner", {Probe.R2.G7.KeeperServer, :"-init/1-fun-0-", 0}},
    {:warning, "ETS table dies with its owner",
     {Probe.R2.G7.KeeperTask, :"-handle_cast/2-fun-0-", 0}},
    {:warning, "ETS table read while its owner may be restarting",
     {Probe.R2.G7.KeeperServer, :lookup, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {Probe.R2.G5.WhereisClauses, :fetch, 2}},
    {:warning, "ETS table read while its owner may be restarting",
     {Probe.R2.G5.WhereisNoted, :lookup, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {Probe.R2.G7.Metrics, :lookup, 1}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.PlugOwner, :call, 2}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.StrategyNamed, :init, 1}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.StrategyKept, :init, 1}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.RatesHelper, :setup, 0}},
    {:warning, "ETS table read while its owner may be restarting",
     {S2c.Ets.RatesHelper, :lookup, 1}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.KeeperMfa, :keep, 0}},
    {:warning, "ETS table read while its owner may be restarting",
     {S2c.Ets.KeeperMfa, :lookup, 1}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.KeeperAsync, :"-warm/0-fun-0-", 0}},
    {:warning, "ETS table dies with its owner", {S2c.Ets.KeeperHanded, :"-init/1-fun-0-", 0}},
    {:warning, "ETS table read while its owner may be restarting",
     {S2c.Ets.KeeperSelfRead, :handle_call, 3}},
    {:warning, "ETS table read while its owner may be restarting",
     {S2c.Ets.WhereisInverted, :fetch, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {S2c.Ets.WhereisOther, :fetch, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {S2c.Ets.WhereisStored, :fetch, 1}},
    {:warning, "ETS table read while its owner may be restarting", {S2c.Ets.Counters, :get, 1}},
    {:warning, "ETS table dies with its owner",
     {S2c.Own.KeeperBeside, :"-start_link/1-fun-0-", 0}},
    {:warning, "ETS table dies with its owner",
     {S2c.Own2.AgentStart, :"-start_link/1-fun-0-", 0}},
    # A read reaches only a table its operand can name: a literal the
    # named table (an unnamed one shares its atom, one creation branch
    # makes it unnamed, options built at run time may name it), a
    # caller's literal through a helper, and a parameter's field whatever
    # the reference is.
    {:warning, "ETS table read while its owner may be restarting",
     {Rows.Ets.NamedServer, :lookup, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {Rows.Ets.OptionNamed, :read, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {Rows.Ets.HelperNamed, :fetch, 2}},
    {:warning, "ETS table read while its owner may be restarting",
     {Rows.Ets.StateTableReader, :peek, 2}},
    {:warning, "ETS table read while its owner may be restarting",
     {Rows.Ets.ConfiguredOptions, :read, 1}},
    # An owner with a restart of its own, beside an application's root:
    # a supervisor another tree also starts, one a start/2 that is no
    # Application's starts, one nothing starts, a worker start/2 starts,
    # a keeper the root spawns, and the root's child.
    {:warning, "ETS table read while its owner may be restarting",
     {:rows_snapshot_reader, :dual, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {:rows_snapshot_reader, :fake, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {:rows_snapshot_reader, :branch, 1}},
    {:warning, "ETS table read while its owner may be restarting",
     {:rows_snapshot_reader, :worker, 1}},
    {:warning, "ETS table read while its owner may be restarting", {:rows_root_tabs, :keeper, 1}},
    {:warning, "ETS table read while its owner may be restarting", {:rows_root_tabs, :child, 1}}
  ]

  @quiet [
    {S2c.Ets.StrategyReturned, :init, 1},
    {S2c.Ets.WhereisGuarded, :fetch, 1},
    {S2c.Ets.WhereisGuarded, :fetch_if, 1},
    {S2c.Ets.Gauges, :get, 1},
    {S2c.Own.AgentStart, :"-start_link/1-fun-0-", 0},
    {Rows.Ets.UnnamedOwner, :first, 0},
    {Rows.Ets.OwnScratchReader, :count, 1},
    {:rows_snapshot_reader, :root, 1},
    {:rows_root_tabs, :lookup, 1}
  ]

  for {severity, title, mfa} <- @fires do
    test "#{inspect(mfa)} keeps #{severity}: #{title}", %{found: found} do
      assert {unquote(severity), unquote(title), unquote(Macro.escape(mfa))} in found
    end
  end

  test "the negatives beside them stay quiet", %{found: found} do
    for mfa <- @quiet, do: refute(Enum.any?(found, &(elem(&1, 2) == mfa)), inspect(mfa))
  end

  test "a literal read is paired with the named table, never the unnamed one of its atom",
       %{reads: reads} do
    owners = fn reader ->
      for [_name, owner, ^reader, _site, _created] <- reads, uniq: true, do: owner
    end

    assert owners.("Rows.Ets.NamedServer:lookup/1") == ["Rows.Ets.NamedServer"]
    assert owners.("Rows.Ets.HelperNamed:get/1") == ["Rows.Ets.HelperNamed"]

    # OptionNamed's two sites share one owner and reader: one row, the
    # named site's, where the unnamed one's used to stand beside it.
    assert [created] =
             for([_, _, "Rows.Ets.OptionNamed:read/1", _, c] <- reads, do: c)

    assert created =~ "Rows.Ets.OptionNamed:init/1#"
  end
end
