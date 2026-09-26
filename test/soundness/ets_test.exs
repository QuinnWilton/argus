defmodule Argus.Soundness.EtsTest do
  @moduledoc """
  Review 2's probes and their adversarial neighbours for the ets analysis:
  real bugs a suppression once silenced, each pinned at the severity the
  rule gives it without the suppression (round sound2c).
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
    :probe_r2_g5_bridge
  ]

  setup_all do
    {:ok, res} = Memo.run_analyses(@modules, analyses: [:ets])
    %{found: MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa})}
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
    {:warning, "ETS table dies with its owner", {S2c.Own2.AgentStart, :"-start_link/1-fun-0-", 0}}
  ]

  @quiet [
    {S2c.Ets.StrategyReturned, :init, 1},
    {S2c.Ets.WhereisGuarded, :fetch, 1},
    {S2c.Ets.WhereisGuarded, :fetch_if, 1},
    {S2c.Ets.Gauges, :get, 1},
    {S2c.Own.AgentStart, :"-start_link/1-fun-0-", 0}
  ]

  for {severity, title, mfa} <- @fires do
    test "#{inspect(mfa)} keeps #{severity}: #{title}", %{found: found} do
      assert {unquote(severity), unquote(title), unquote(Macro.escape(mfa))} in found
    end
  end

  test "the negatives beside them stay quiet", %{found: found} do
    for mfa <- @quiet, do: refute(Enum.any?(found, &(elem(&1, 2) == mfa)), inspect(mfa))
  end
end
