defmodule Argus.Analyses.MailboxSocketTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.Sockets, as: F
  alias Argus.Test.Memo

  # Every test but the wrapper's quiet twin, which shares the wrapper
  # module with its positive, reads its rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    [F.ActiveTcp],
    [F.ActiveTcpHandled],
    [F.PassiveTcp],
    [F.DefaultActive],
    [F.TlsTakesTcpClose],
    [F.TlsTakesBoth],
    [F.Wrapped.Socket, F.Wrapped.Client],
    [F.LogsTheRest],
    [F.HandsTheRestOn],
    [F.HandsOff],
    [F.HandsOffInHelper],
    [F.HandsOffFromClosures],
    [F.WaitsForIt],
    [F.InetTcp],
    [F.InetUdp],
    [F.ThroughTransport],
    [F.StatemTcp],
    [F.StatemHandsOn],
    [F.OneStateHandsOn]
  ]

  setup_all do
    %{batch: Batch.solve(:mailbox, @batched)}
  end

  # {server, message, fallback} for each socket row of the set.
  defp closes({:ok, results}) do
    rows =
      for [_mod, _func, _site, message, "socket", server, _handler, fallback] <-
            results["unhandled_info"],
          uniq: true,
          do: {short(server), message, fallback}

    Enum.sort(rows)
  end

  defp closes(%{batch: batch}, modules), do: closes(Batch.analyze(batch, modules))

  defp short(module), do: module |> String.split(".") |> List.last()

  describe "a socket the server makes active" do
    test "a TCP connect with active: true and no clause for its close crashes", ctx do
      assert closes(ctx, [F.ActiveTcp]) == [{"ActiveTcp", "{:tcp_closed, …}", "crash"}]
    end

    test "a clause for the close is quiet", ctx do
      assert closes(ctx, [F.ActiveTcpHandled]) == []
    end

    test "a passive socket sends no close", ctx do
      assert closes(ctx, [F.PassiveTcp]) == []
    end

    test "options that leave :active out leave the socket active", ctx do
      assert closes(ctx, [F.DefaultActive]) == [{"DefaultActive", "{:tcp_closed, …}", "crash"}]
    end
  end

  describe "a TLS socket" do
    test "a clause for the TCP close does not take the TLS one", ctx do
      assert closes(ctx, [F.TlsTakesTcpClose]) ==
               [{"TlsTakesTcpClose", "{:ssl_closed, …}", "crash"}]
    end

    test "a clause for each is quiet", ctx do
      assert closes(ctx, [F.TlsTakesBoth]) == []
    end
  end

  describe "a socket made active through a wrapper" do
    test "the literal a caller hands the wrapper makes either kind the server connects active",
         ctx do
      assert closes(ctx, [F.Wrapped.Socket, F.Wrapped.Client]) == [
               {"Client", "{:ssl_closed, …}", "crash"},
               {"Client", "{:tcp_closed, …}", "crash"}
             ]
    end

    test "a server with a clause for each is quiet" do
      assert closes(Memo.analyze([F.Wrapped.Socket, F.Wrapped.HandledClient], :mailbox)) == []
    end
  end

  describe "where the close goes instead" do
    test "a catch-all that only logs it keeps a dead socket", ctx do
      assert closes(ctx, [F.LogsTheRest]) == [{"LogsTheRest", "{:tcp_closed, …}", "catch_all"}]
    end

    test "a catch-all that hands the message on is not judged", ctx do
      assert closes(ctx, [F.HandsTheRestOn]) == []
    end

    test "a socket handed to another process sends its messages there", ctx do
      assert closes(ctx, [F.HandsOff]) == []
      assert closes(ctx, [F.HandsOffInHelper]) == []
      assert closes(ctx, [F.HandsOffFromClosures]) == []
    end

    test "a receive in the callback that takes the close is quiet", ctx do
      assert closes(ctx, [F.WaitsForIt]) == []
    end

    test "a gen_statem with no :info catch-all crashes in that state", ctx do
      assert closes(ctx, [F.StatemTcp]) == [{"StatemTcp", "{:tcp_closed, …}", "state_crash"}]
    end

    test "an :info clause that takes any content, whatever it asks of the data, is a catch-all",
         ctx do
      assert closes(ctx, [F.StatemHandsOn]) == []
    end

    # Review 2, item 34: a handle_event/4 clause naming a state is that
    # state's catch-all, not the machine's; that the machine has no other
    # state is not read, so Postgrex's one-state shape is reported (a
    # known false positive, a prior candidate), where a two-state
    # machine's message in its other state is a real crash.
    test "handle_event/4's clause for one state is no catch-all for the machine", ctx do
      assert closes(ctx, [F.OneStateHandsOn]) == [
               {"OneStateHandsOn", "{:tcp_closed, …}", "state_crash"}
             ]
    end
  end

  describe "which close a setopts means" do
    test ":inet.setopts on a TCP socket the server connected", ctx do
      assert closes(ctx, [F.InetTcp]) == [{"InetTcp", "{:tcp_closed, …}", "crash"}]
    end

    test ":inet.setopts on a UDP socket, which has no close, is quiet", ctx do
      assert closes(ctx, [F.InetUdp]) == []
    end

    test "a transport module in a variable means the kind the server connects", ctx do
      assert closes(ctx, [F.ThroughTransport]) ==
               [{"ThroughTransport", "{:tcp_closed, …}", "crash"}]
    end
  end

  describe "the finding" do
    test "is anchored at the handler, one per server, with the activation as a frame" do
      {:ok, %{findings: findings}} =
        Memo.run_analyses([F.Wrapped.Socket, F.Wrapped.Client], analyses: [:mailbox])

      assert [finding] =
               Enum.filter(findings, &(&1.title =~ "the close of the server's socket"))

      assert finding.title == "No handle_info/2 clause for the close of the server's socket"
      assert finding.severity == :warning
      assert inspect(finding.module) =~ "Wrapped.Client"
      assert Enum.any?(finding.related, &(&1.label == "the socket is made active here"))
    end
  end
end
