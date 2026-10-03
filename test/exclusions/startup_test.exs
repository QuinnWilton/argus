defmodule Argus.Exclusions.StartupTest do
  @moduledoc """
  Regression cases for startup exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/startup.ex.
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.Test.Batch
  alias Argus.Test.Rows
  alias Excl.Startup, as: S

  @tag_conditional [S.TagConditional.WorkerRegistry, S.TagConditional.Worker]
  @tag_after_ack [S.TagAfterAck.WorkerRegistry, S.TagAfterAck.Worker]
  @call_after_ack [S.CallAfterAck.Config, S.CallAfterAck.Worker]
  @later_sibling [
    S.ConditionalLaterSibling.Cache,
    S.ConditionalLaterSibling.Store,
    S.ConditionalLaterSibling.Sup
  ]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    @tag_conditional,
    @tag_after_ack,
    @call_after_ack,
    @later_sibling,
    [S.WaitAfterAck.Wire],
    [S.WaitAfterAck.Helper],
    [S.RemoteAfterAck.GlobalName],
    [S.RemoteAfterAck.Peering],
    [S.RemoteAfterAck.Journal],
    [S.RemoteBeforeAck.Node],
    [S.LockAfterAck.Leader],
    [S.LockBeforeAck.Leader],
    [S.TaskAfterAck.Elector],
    [S.TaskBeforeAck.Elector]
  ]

  @fixture Path.expand("../fixtures/exclusions/startup.ex", __DIR__)

  setup_all do
    %{batch: Batch.solve(:startup, @batched)}
  end

  defp results(%{batch: batch}, set) do
    {:ok, results} = Batch.analyze(batch, set)
    results
  end

  # {dependency, ordering, detail, site} of each wait that holds a start.
  defp peers(ctx, set) do
    for [dep, ordering, site, detail] <-
          Rows.where(results(ctx, set), :startup, "blocks_on_peer",
            drop: [:mod, :phase, :kind, :sup]
          ),
        do: {dep, ordering, detail, site}
  end

  defp details(ctx, set), do: for({_, _, detail, _} <- peers(ctx, set), do: detail)

  # The source lines the sites resolve to, in the order given.
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

  describe "a call init/1 makes to a peer" do
    # startup.dl, unconditional_sync_call_in_init: !conditional_call(id).
    test "made to a pid handed in, only when one is configured, holds the start conditionally",
         ctx do
      assert [{"Excl.Startup.TagConditional.WorkerRegistry", "unknown", "conditional", _}] =
               peers(ctx, @tag_conditional)
    end

    # startup.dl, unconditional_sync_call_in_init: !start_acked(id, func).
    test "made before the ack only when asked to holds the start conditionally", ctx do
      assert details(ctx, @tag_after_ack) == ["conditional"]
    end

    # startup.dl, init_wait_site: !start_acked(id, f), the rule for a call
    # its tag attributes.
    test "made to a pid handed in after the ack holds the server, not the start", ctx do
      sites = for {_, _, _, site} <- peers(ctx, @tag_after_ack), do: site
      assert lines(@tag_after_ack, sites) == [fixture_line("      register(registry)")]
    end

    # startup.dl, init_wait_site: !start_acked(id, f), in the rule for
    # the waiting call itself and in the rule for a call into the client
    # API that makes it.
    test "made by name after the ack holds the server, not the start", ctx do
      sites = for {_, _, _, site} <- peers(ctx, @call_after_ack), do: site
      assert lines(@call_after_ack, sites) == [fixture_line("pool = Config.fetch(:pool_size)")]
    end

    # startup.dl, call_to_unplaced_peer_during_init: !later_sibling_call(mod, peer).
    test "made on some starts to a later sibling is the start order's finding alone", ctx do
      assert [{"Excl.Startup.ConditionalLaterSibling.Store", "later", _, _}] =
               peers(ctx, @later_sibling)
    end
  end

  describe "a wait init/1 reaches through a helper" do
    # startup.dl, init_recv_step: !acked_edge(f, g), for a socket read.
    test "a socket read after the ack holds the server, not the start", ctx do
      calls =
        for [call] <-
              Rows.where(results(ctx, [S.WaitAfterAck.Wire]), :startup, "init_reaches_recv",
                drop: [:mod, :api]
              ),
            do: call

      assert lines([S.WaitAfterAck.Wire], calls) == [fixture_line("greeting = recv_line(sock)")]
    end

    # startup.dl, init_recv_step: !acked_edge(f, g), for a receive.
    test "a receive after the ack holds the server, not the start", ctx do
      calls =
        for [call] <-
              Rows.where(results(ctx, [S.WaitAfterAck.Helper]), :startup, "init_reaches_recv",
                drop: [:mod, :api]
              ),
            do: call

      assert lines([S.WaitAfterAck.Helper], calls) == [fixture_line(":ok = await_ready(port)")]
    end
  end

  describe "distributed work after the ack" do
    # startup.dl, blocks_on_peer: !start_acked(id, func), the global name
    # rule.
    test "a global name registered after the ack", ctx do
      assert peers(ctx, [S.RemoteAfterAck.GlobalName]) == []
      assert "global_register" in details(ctx, [S.RemoteBeforeAck.Node])
    end

    # startup.dl, blocks_on_peer: !start_acked(id, func), the connect rule.
    test "a node connected after the ack", ctx do
      assert peers(ctx, [S.RemoteAfterAck.Peering]) == []
      assert "connect" in details(ctx, [S.RemoteBeforeAck.Node])
    end

    # startup.dl, blocks_on_peer: !start_acked(id, func), the dets rule.
    test "a dets table opened after the ack", ctx do
      assert peers(ctx, [S.RemoteAfterAck.Journal]) == []
      assert "open_file" in details(ctx, [S.RemoteBeforeAck.Node])
    end
  end

  describe "a cluster-wide lock after the ack" do
    # global_reach.dl, global_path: !acked_edge(f, g).
    test "taken through a helper init/1 calls after the ack", ctx do
      assert peers(ctx, [S.LockAfterAck.Leader]) == []
      assert details(ctx, [S.LockBeforeAck.Leader]) == ["trans"]
    end

    # global_reach.dl, global_path: !start_acked(id, f).
    test "taken in a task init/1 awaits after the ack", ctx do
      assert peers(ctx, [S.TaskAfterAck.Elector]) == []
      assert details(ctx, [S.TaskBeforeAck.Elector]) == ["trans"]
    end
  end
end
