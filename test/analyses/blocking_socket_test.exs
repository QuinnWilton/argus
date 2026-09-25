defmodule Argus.Analyses.BlockingSocketTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.Sockets, as: F

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    [F.RecvInCallback],
    [F.RecvBounded],
    [F.RecvInTask],
    [F.RecvInInit],
    [F.ReconnectsInCall],
    [F.ReconnectsBounded],
    [F.HandshakeInState],
    [F.HandshakeBounded],
    [F.InfinityThroughHelper]
  ]

  setup_all do
    %{batch: Batch.solve(:blocking, @batched)}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # {function, api, server} for each socket wait of the set.
  defp waits(%{batch: batch}, modules) do
    {:ok, results} = Batch.analyze(batch, modules)

    rows =
      for [func, _site, "socket", api, server, _] <- results["unbounded_wait"],
          uniq: true,
          do: {short(func), api, short(server)}

    Enum.sort(rows)
  end

  defp short(id), do: id |> String.split(".") |> List.last()

  describe "a socket call with no timeout on a callback's stack" do
    test "a recv/2 in handle_info/2", ctx do
      skip_without_souffle()

      assert waits(ctx, [F.RecvInCallback]) ==
               [{"RecvInCallback:handle_info/2", ":gen_tcp.recv/2", "RecvInCallback"}]
    end

    test "a connect/3 two calls below handle_call/3", ctx do
      skip_without_souffle()

      assert waits(ctx, [F.ReconnectsInCall]) ==
               [{"ReconnectsInCall:connect/2", ":gen_tcp.connect/3", "ReconnectsInCall"}]
    end

    test "an :ssl.handshake/2 with options in a gen_statem's handle_event/4", ctx do
      skip_without_souffle()

      assert waits(ctx, [F.HandshakeInState]) ==
               [{"HandshakeInState:handle_event/4", ":ssl.handshake/2", "HandshakeInState"}]
    end

    test "a recv/3 whose timeout a caller passes as :infinity", ctx do
      skip_without_souffle()

      assert waits(ctx, [F.InfinityThroughHelper]) ==
               [{"InfinityThroughHelper:read/2", ":gen_tcp.recv/3", "InfinityThroughHelper"}]
    end
  end

  describe "quiet" do
    test "a finite timeout bounds each of them", ctx do
      skip_without_souffle()
      assert waits(ctx, [F.RecvBounded]) == []
      assert waits(ctx, [F.ReconnectsBounded]) == []
      assert waits(ctx, [F.HandshakeBounded]) == []
    end

    test "a wait in a task the callback starts is the task's", ctx do
      skip_without_souffle()
      assert waits(ctx, [F.RecvInTask]) == []
    end

    test "a recv init/1 makes is startup's finding", ctx do
      skip_without_souffle()
      assert waits(ctx, [F.RecvInInit]) == []
    end
  end
end
