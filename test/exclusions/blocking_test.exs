defmodule Argus.Exclusions.BlockingTest do
  @moduledoc """
  Regression cases for blocking exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/blocking.ex.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Blocking, as: B

  @cycle_on_path [
    B.CycleOnPath.Ledger,
    B.CycleOnPath.Pricing,
    B.CycleOnPath.Warehouse,
    B.CycleOnPath.Inventory,
    B.CycleOnPath.Gateway
  ]
  @own_capture [B.OwnCapture.Directory, B.OwnCapture.Frontend]
  @foreign_capture [
    B.ForeignCapture.Directory,
    B.ForeignCapture.Format,
    B.ForeignCapture.Frontend
  ]
  @foreign_capture_rpc [B.ForeignCaptureRpc.ClusterInfo, B.ForeignCaptureRpc.Summary]
  @called_and_handed [B.CalledAndHanded.Catalog, B.CalledAndHanded.Cart]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    @cycle_on_path,
    @own_capture,
    @foreign_capture,
    [B.OwnCaptureRpc.ClusterInfo],
    @foreign_capture_rpc,
    [B.FlushWithDown.Runner],
    [B.WaitWithDown.Runner],
    [B.FlushWithExit.Command],
    [B.WaitWithExit.Command],
    @called_and_handed,
    [B.HandedAndInline.Exporter],
    [B.HandedAndCalled.Exporter],
    [B.RuntimeTick.Poller],
    [B.RuntimeTickWait.Poller],
    [B.RenamedTick.Refresher]
  ]

  @fixture Path.expand("../fixtures/exclusions/blocking.ex", __DIR__)

  setup_all do
    %{batch: Batch.solve(:blocking, @batched)}
  end

  defp results(%{batch: batch}, set) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)
    results
  end

  # {caller, callee, inferred, site} of each call chain.
  defp chains(ctx, set) do
    for [from, to, inferred, site] <-
          Rows.where(results(ctx, set), :blocking, "call_chain",
            drop: [:kind, :depth, :caller_ms, :downstream_ms, :peer, :permille]
          ),
        do: {short_module(from), short_module(to), inferred, site}
  end

  # {function, kind, peer or api} of each unbounded wait.
  defp waits(ctx, set) do
    for [func, kind, api] <-
          Rows.where(results(ctx, set), :blocking, "unbounded_wait",
            drop: [:site, :detail, :nodes, :peer, :permille]
          ),
        do: {short(func), kind, api}
  end

  # {receiving function, callback, bounded} of each receive in a callback.
  defp receives(ctx, set) do
    for [func, callback, bounded] <-
          Rows.where(results(ctx, set), :blocking, "receive_in_callback",
            drop: [:id, :behaviour, :proximity]
          ),
        do: {short(func), short(callback), bounded}
  end

  defp short(func), do: func |> String.split(":") |> List.last()
  defp short_module(mod), do: mod |> String.split(".") |> List.last()

  # The source lines the sites of `set`'s rows resolve to.
  defp lines(set, sites) do
    {:ok, facts} = Argus.Pipeline.extract(set)
    table = Argus.Lines.from_facts(facts)
    Enum.map(sites, &Argus.Lines.resolve(table, &1))
  end

  # The fixture's line holding `text`, found by the text so the fixture
  # can move freely.
  defp fixture_line(text) do
    @fixture
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_index(&String.contains?(&1, text))
    |> Kernel.+(1)
  end

  describe "a call chain with a call cycle on another path" do
    # blocking.dl, request_chain_inferred: !chain_cycle_clause(mid, mid_clause).
    test "is inferred from its static path, not from the tag on the path through the cycle",
         ctx do
      assert [{"Gateway", "Ledger", "static", _}] = chains(ctx, @cycle_on_path)

      assert [["Excl.Blocking.CycleOnPath.Inventory", "Excl.Blocking.CycleOnPath.Warehouse"]] =
               Rows.where(results(ctx, @cycle_on_path), :blocking, "call_cycle",
                 drop: [:witness_a, :witness_b, :phase, :site_a, :site_b]
               )
    end

    # blocking.dl, chain_site: !chain_cycle_clause(mid, mid_clause).
    test "is anchored only at the call that starts its static path", ctx do
      sites = for {"Gateway", "Ledger", _, site} <- chains(ctx, @cycle_on_path), do: site

      assert lines(@cycle_on_path, sites) ==
               [fixture_line("price = GenServer.call(Excl.Blocking.CycleOnPath.Pricing, :price)")]
    end
  end

  describe "a call chain whose callee is also handed as a capture" do
    # calls.dl, site_request: !call_instr(f, g, _).
    test "is anchored only at the direct call", ctx do
      sites = for {"Cart", "Catalog", _, site} <- chains(ctx, @called_and_handed), do: site
      assert lines(@called_and_handed, sites) == [fixture_line("first = Catalog.price(headline)")]
    end
  end

  describe "a remote capture of the module's own function" do
    # blocking.dl, call_waits: !function_def(g, own, _, _, _).
    test "handed to Enum.map in a handler others call with :infinity answers at once", ctx do
      assert waits(ctx, @own_capture) == []

      assert waits(ctx, @foreign_capture) ==
               [{"handle_call/3", "infinity", "Excl.Blocking.ForeignCapture.Directory"}]
    end

    # blocking.dl, fun_waits: !function_def(g, own, _, _, _).
    test "in an rpc closure with the default :infinity timeout answers at once", ctx do
      assert waits(ctx, [B.OwnCaptureRpc.ClusterInfo]) == []
      assert waits(ctx, @foreign_capture_rpc) == [{"counts/1", "rpc", "erpc"}]
    end
  end

  describe "the cancel_timer flush" do
    # blocking.dl, receive_in_callback: !flush_receive(id), the rule for a
    # receive a :DOWN bounds.
    test "a flush that also takes a monitored worker's :DOWN", ctx do
      refute Enum.any?(receives(ctx, [B.FlushWithDown.Runner]), &match?({_, _, "down"}, &1))

      assert receives(ctx, [B.WaitWithDown.Runner]) ==
               [{"handle_info/2", "handle_info/2", "down"}]
    end

    # blocking.dl, receive_in_callback: !flush_receive(id), the rule for a
    # receive a trapped :EXIT bounds.
    test "a flush that also takes a linked port's :EXIT in a trapping server", ctx do
      refute Enum.any?(receives(ctx, [B.FlushWithExit.Command]), &match?({_, _, "down"}, &1))

      # The outer receive, waiting 5 s for the port's exit status, runs
      # before the cancel: a bounded wait in the callback, no flush.
      assert receives(ctx, [B.WaitWithExit.Command]) ==
               [
                 {"handle_call/3", "handle_call/3", "true"},
                 {"handle_call/3", "handle_call/3", "down"}
               ]
    end

    # timer_flush.dl, waits_for_other: !timer_message_unknown(mod).
    test "a flush of tick messages the module arms only through a variable", ctx do
      assert receives(ctx, [B.RuntimeTick.Poller]) == []

      assert receives(ctx, [B.RuntimeTickWait.Poller]) ==
               [{"handle_call/3", "handle_call/3", "false"}]
    end

    # timer_flush.dl, flush_receive: !waits_for_other(id).
    test "kept: a flush waiting for a message no timer of the module carries", ctx do
      assert receives(ctx, [B.RenamedTick.Refresher]) ==
               [{"handle_call/3", "handle_call/3", "false"}]
    end
  end

  describe "kept: a closure that runs elsewhere and on the callback's stack" do
    # runs_elsewhere.dl, runs_elsewhere: !runs_handed(f, g).
    test "handed to a Task-starting helper and to a helper that runs it inline", ctx do
      assert receives(ctx, [B.HandedAndInline.Exporter]) ==
               [{"-handle_call/3-fun-0-/2", "handle_call/3", "false"}]
    end

    # runs_elsewhere.dl, runs_elsewhere: !call_instr(f, g, _).
    test "handed to a Task-starting helper and called directly", ctx do
      assert receives(ctx, [B.HandedAndCalled.Exporter]) ==
               [{"-handle_call/3-fun-0-/2", "handle_call/3", "false"}]
    end
  end
end
