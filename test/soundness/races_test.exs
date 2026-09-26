defmodule Argus.Soundness.RacesTest do
  @moduledoc """
  Review 2's probes and their adversarial neighbours for the races analysis:
  real bugs a suppression once silenced, each pinned at the severity the
  rule gives it without the suppression (round sound2c).
  """
  use ExUnit.Case, async: true

  alias Argus.Test.Memo

  @modules [
    Probe.R2.G7.Advance,
    Probe.R2.G7.MnesiaAdvance,
    Probe.R2.G7.ToggleHelper,
    S2c.Races.AdvanceInline,
    S2c.Races.AdvanceTwoDeep,
    S2c.Races.Stages,
    S2c.Races.AdvanceRemote,
    S2c.Races.AdvanceVar
  ]

  setup_all do
    {:ok, res} = Memo.run_analyses(@modules, analyses: [:races])
    %{found: MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa})}
  end

  @fires [
    {:warning, "Read-then-write race on an ETS key", {Probe.R2.G7.Advance, :advance, 1}},
    {:warning, "Read-then-write race on an ETS key", {Probe.R2.G7.ToggleHelper, :flip, 1}},
    {:warning, "Read-then-write race on an ETS key", {S2c.Races.AdvanceInline, :advance, 1}},
    {:warning, "Read-then-write race on an ETS key", {S2c.Races.AdvanceRemote, :advance, 1}},
    {:warning, "Read-then-write race on an ETS key", {S2c.Races.AdvanceVar, :advance, 1}}
  ]

  @quiet []

  for {severity, title, mfa} <- @fires do
    test "#{inspect(mfa)} keeps #{severity}: #{title}", %{found: found} do
      assert {unquote(severity), unquote(title), unquote(Macro.escape(mfa))} in found
    end
  end

  test "the negatives beside them stay quiet", %{found: found} do
    for mfa <- @quiet, do: refute(Enum.any?(found, &(elem(&1, 2) == mfa)), inspect(mfa))
  end
end
