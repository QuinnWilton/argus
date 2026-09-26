defmodule Argus.Soundness.RacesTest do
  @moduledoc """
  Soundness programs for the races analysis, each solved alone: a real
  race its finding must keep (`Argus.Test.Soundness`). A check-then-act
  pair whose function runs in one process races a write another process
  makes: another entry's, whether or not the owner's own process calls it
  too, or a caller's outside the program. Review 2's probes are kept at
  the end.
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Memo
  alias Argus.Test.Soundness.Races, as: R

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

  describe "the census's counter-examples" do
    test "a counter's reset/1 shared with a janitor in another process" do
      assert_fires([R.JanitorCounter, R.Janitor], @ets, {R.JanitorCounter, :handle_call, 3})
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

  describe "the quiet controls" do
    test "a counter only its own process writes" do
      assert_quiet([R.CounterSelf])
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
