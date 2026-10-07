defmodule Argus.Exclusions.ShutdownTest do
  @moduledoc """
  Regression cases for shutdown exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/shutdown.ex.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Shutdown, as: S

  @guarded_farewell [S.GuardedFarewell.Sup, S.GuardedFarewell.Events, S.GuardedFarewell.Watchman]
  @bare_farewell [S.BareFarewell.Sup, S.BareFarewell.Events, S.BareFarewell.Watchman]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    @guarded_farewell,
    @bare_farewell,
    [S.SharedTrap.PortOwner],
    [S.StatemInfoHelper.Conn],
    [S.ServerInfo.Conn]
  ]

  setup_all do
    %{batch: Batch.solve(:shutdown, @batched)}
  end

  # The set's rows of `relation`, with the `drop` columns removed.
  defp rows(%{batch: batch}, set, relation, drop) do
    {:ok, results} = Batch.analyze(batch, set)
    Rows.where(results, :shutdown, relation, drop: drop)
  end

  defp farewells(ctx, set),
    do:
      rows(ctx, set, "teardown_touches_sibling", [
        :mod,
        :sibling,
        :via,
        :sup,
        :handler,
        :site,
        :sup_site
      ])

  # {kind, witness function} of each unhandled exit signal.
  defp exit_signals(ctx, set) do
    for [kind, witness] <- rows(ctx, set, "unhandled_exit_signal", [:mod]),
        do: {kind, witness |> String.split(":") |> List.last()}
  end

  describe "a sibling called from terminate/2" do
    # shutdown.dl, stop_wait: !catches_exit(f).
    test "a call to a later sibling under a try that takes its :noproc exit", ctx do
      assert farewells(ctx, @guarded_farewell) == []
      assert farewells(ctx, @bare_farewell) == [["terminate", "call"]]
    end
  end

  describe "a trapping process without an {:EXIT, ...} clause" do
    # process_kind.dl, traps_elsewhere: !call_instr(_, func, _).
    test "kept: a trapping function the server's init/1 calls, though a spawn also runs it",
         ctx do
      assert exit_signals(ctx, [S.SharedTrap.PortOwner]) == [{"no_exit_clause", "listen/1"}]
    end

    # process_kind.dl, trap_exit_without_exit_clause: !statem_process(mod).
    test "a gen_statem whose handle_info/2 is a helper handle_event/4 delegates to", ctx do
      assert exit_signals(ctx, [S.StatemInfoHelper.Conn]) == []
      assert exit_signals(ctx, [S.ServerInfo.Conn]) == [{"no_exit_clause", "init/1"}]
    end
  end
end
