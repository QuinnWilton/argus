defmodule Argus.Soundness.FailureTest do
  @moduledoc """
  Review 2's probes and their adversarial neighbours for the failure analysis:
  real bugs a suppression once silenced, each pinned at the severity the
  rule gives it without the suppression (round sound2c).
  """
  use ExUnit.Case, async: true

  alias Argus.Test.Memo

  @modules [
    Probe.R2.G5.LogInline,
    Probe.R2.G5.LogDynamic,
    Probe.R2.G5.RoleApi,
    Probe.R2.G5.RoleCaller,
    Probe.R2.G10.BoundaryErpc,
    Probe.R2.G10.BoundaryStartChild,
    Probe.R2.G10.NoChildSpec,
    Probe.R2.G10.WhereisBifValue,
    Probe.R2.G10.WhereisRescueExit,
    S2c.Fail.LogWork,
    S2c.Fail.GuardApi,
    S2c.Fail.GuardCaller,
    S2c.Fail.Whereis,
    S2c.Fail.Erpc,
    :probe_r2_g5_logmacro
  ]

  setup_all do
    {:ok, res} = Memo.run_analyses(@modules, analyses: [:failure])
    %{found: MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa})}
  end

  @fires [
    {:warning, "Catch-all rescue swallows exceptions",
     {Probe.R2.G5.LogInline, :apply_and_log, 2}},
    {:warning, "Catch-all rescue swallows exceptions", {Probe.R2.G5.LogDynamic, :append, 2}},
    {:warning, "Catch-all rescue swallows exceptions",
     {:probe_r2_g5_logmacro, :apply_and_log, 2}},
    {:warning, "Catch-all rescue swallows exceptions", {S2c.Fail.LogWork, :run, 1}},
    {:warning, "Catch-all rescue swallows exceptions", {S2c.Fail.LogWork, :wal, 2}},
    {:warning, "Catch-all rescue swallows exceptions", {Probe.R2.G5.RoleCaller, :read, 2}},
    {:warning, "Catch-all rescue swallows exceptions", {Probe.R2.G5.RoleCaller, :health, 1}},
    {:warning, "Catch-all rescue swallows exceptions", {S2c.Fail.GuardCaller, :a, 1}},
    {:warning, "Catch-all rescue swallows exceptions", {S2c.Fail.GuardCaller, :b, 1}},
    {:warning, "Catch-all rescue swallows exceptions",
     {Probe.R2.G10.BoundaryErpc, :fetch_remote, 2}},
    {:warning, "Catch-all rescue swallows exceptions",
     {Probe.R2.G10.BoundaryStartChild, :start_worker, 2}},
    {:warning, "Catch-all rescue swallows exceptions", {S2c.Fail.Erpc, :b, 1}},
    {:warning, "Catch-all rescue swallows exceptions", {S2c.Fail.Erpc, :c, 1}},
    {:warning, "whereis result used without a nil check",
     {Probe.R2.G10.WhereisBifValue, :notify, 1}},
    {:warning, "whereis result used without a nil check",
     {Probe.R2.G10.WhereisBifValue, :notify_is_pid, 1}},
    {:warning, "whereis result used without a nil check",
     {Probe.R2.G10.WhereisRescueExit, :ping, 0}},
    {:warning, "whereis result used without a nil check", {S2c.Fail.Whereis, :poke, 0}},
    {:warning, "whereis result used without a nil check", {S2c.Fail.Whereis, :stop, 0}},
    {:warning, "whereis result used without a nil check", {S2c.Fail.Whereis, :tell, 1}}
  ]

  @quiet [
    {S2c.Fail.LogWork, :fine, 1},
    {S2c.Fail.GuardCaller, :c, 1},
    {S2c.Fail.Whereis, :safe, 1}
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
