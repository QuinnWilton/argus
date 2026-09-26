defmodule Argus.Soundness.BlockingTest do
  @moduledoc """
  Review 2's probes and their adversarial neighbours for the blocking analysis:
  real bugs a suppression once silenced, each pinned at the severity the
  rule gives it without the suppression (round sound2c).
  """
  use ExUnit.Case, async: true

  alias Argus.Test.Memo
  alias Argus.Test.Soundness.Census.Blocking, as: C

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

  # The exclusion census's blocking holes (docs/design/exclusions.md), over
  # one fixture set (test/fixtures/soundness/blocking_census.ex).
  @census [
    C.Ring3A,
    C.Ring3B,
    C.Ring3C,
    C.Ring4Z,
    C.Ring4Y,
    C.Ring4M,
    C.Ring4B,
    C.TaskRingA,
    C.TaskRingB,
    C.TaskRingC,
    C.LineA,
    C.LineB,
    C.LineC,
    C.NavParent,
    C.NoprocAndShutdown,
    C.NoprocAndNormal,
    C.NoprocAndBareShutdown,
    C.EveryStopShape,
    C.NoprocAndInnerNoproc,
    C.NoprocAndInnerShutdown
  ]

  defp census do
    {:ok, res} = Memo.run_analyses(@census, analyses: [:blocking])
    {:ok, rows} = Memo.analyze(@census, :blocking)
    {MapSet.new(res.findings, &{&1.severity, &1.title, &1.mfa}), rows}
  end

  # census: rings
  # A cycle of waits longer than two: call_cycle knew only pairs, and the
  # chain rule stops at a clause on a cycle.
  describe "census hole: a cycle of three or more servers" do
    test "a ring of three servers is one cycle, from its least module" do
      {found, rows} = census()
      assert {:error, "Synchronous call cycle", {C.Ring3A, :handle_call, 3}} in found

      assert [[a, b | _]] =
               for(r = [a | _] <- rows["call_cycle"], a == inspect(C.Ring3A), do: r)

      assert {a, b} == {inspect(C.Ring3A), inspect(C.Ring3B)}

      edges =
        for [^a, ^b, from, to | _] <- rows["call_cycle_path"], uniq: true, do: {from, to}

      assert Enum.sort(edges) ==
               Enum.sort([
                 {inspect(C.Ring3A), inspect(C.Ring3B)},
                 {inspect(C.Ring3B), inspect(C.Ring3C)},
                 {inspect(C.Ring3C), inspect(C.Ring3A)}
               ])
    end

    test "a ring of four through a helper and a handle_info is reported once" do
      {found, _rows} = census()

      cycles =
        for {_, "Synchronous call cycle", {m, _, _}} <- found,
            m in [C.Ring4Z, C.Ring4Y, C.Ring4M, C.Ring4B],
            do: m

      assert cycles == [C.Ring4B]
    end

    test "a ring whose first wait is in a task the server awaits is reported" do
      {found, _rows} = census()

      assert {:error, "Synchronous call cycle", {C.TaskRingA, :"-handle_call/3-fun-0-", 0}} in found
    end

    test "a chain that does not close, or closes only through a client function, is no cycle" do
      {found, _rows} = census()

      refute Enum.any?(found, fn {_, t, {m, _, _}} ->
               t == "Synchronous call cycle" and m in [C.LineA, C.LineB, C.LineC]
             end)
    end
  end

  # census: catch-shapes
  # A catch for the peer's bare :shutdown was taken for its shutdown with a
  # reason: the catch facts could not tell the two apart.
  describe "census hole: a catch for the bare :shutdown" do
    for mod <- [C.NoprocAndShutdown, C.NoprocAndBareShutdown, C.NoprocAndInnerNoproc] do
      test "#{inspect(mod)}: a catch that takes no stop the peer makes itself is reported" do
        {found, _rows} = census()

        assert {:warning, "Peer call catches :noproc but not :shutdown",
                {unquote(mod), :sync_with_parent, 1}} in found
      end
    end

    test "a catch for {{:shutdown, _}, _} (b100e10's fix), or for {:normal, _}, is quiet" do
      {found, _rows} = census()

      for mod <- [C.NoprocAndInnerShutdown, C.EveryStopShape, C.NoprocAndNormal] do
        refute Enum.any?(found, &(elem(&1, 2) == {mod, :sync_with_parent, 1})), inspect(mod)
      end
    end
  end
end
