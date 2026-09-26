defmodule Argus.Soundness.BlockingTest do
  @moduledoc """
  Review 2's probes and their adversarial neighbours for the blocking analysis:
  real bugs a suppression once silenced, each pinned at the severity the
  rule gives it without the suppression (round sound2c).
  """
  use ExUnit.Case, async: true

  alias Argus.Test.Memo

  @modules [
    Probe.R2.G5.NoprocAndReexit,
    Probe.R2.G5.NoprocAndAllButShutdown,
    S2c.Catch.ReraiseErlang,
    S2c.Catch.ShutdownReexit,
    S2c.Catch.AnyExitReexit,
    S2c.Catch.OpenKept
  ]

  setup_all do
    {:ok, res} = Memo.run_analyses(@modules, analyses: [:blocking])
    %{found: MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa})}
  end

  @fires [
    {:warning, "Peer call catches :noproc but not :shutdown",
     {Probe.R2.G5.NoprocAndReexit, :sync_with_parent, 1}},
    {:warning, "Peer call catches :noproc but not :shutdown",
     {Probe.R2.G5.NoprocAndAllButShutdown, :sync_with_parent, 1}},
    {:warning, "Peer call catches :noproc but not :shutdown",
     {S2c.Catch.ReraiseErlang, :sync, 1}},
    {:warning, "Peer call catches :noproc but not :shutdown",
     {S2c.Catch.ShutdownReexit, :sync, 1}},
    {:warning, "Peer call catches :noproc but not :shutdown", {S2c.Catch.AnyExitReexit, :sync, 1}}
  ]

  @quiet [{S2c.Catch.OpenKept, :sync, 1}, {:s2c_catch_many, :safe_call, 2}]

  for {severity, title, mfa} <- @fires do
    test "#{inspect(mfa)} keeps #{severity}: #{title}", %{found: found} do
      assert {unquote(severity), unquote(title), unquote(Macro.escape(mfa))} in found
    end
  end

  test "the negatives beside them stay quiet", %{found: found} do
    for mfa <- @quiet, do: refute(Enum.any?(found, &(elem(&1, 2) == mfa)), inspect(mfa))
  end
end
