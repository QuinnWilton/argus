defmodule Argus.FlowLog.WorkersTest do
  @moduledoc """
  How many worker threads an engine runs (`Argus.FlowLog.workers/2`), in
  a peer: `ARGUS_FLOWLOG_WORKERS` is VM-wide.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.FlowLog
  alias Argus.Test.Peer

  setup do
    peer = Peer.start!()
    Peer.run(peer, fn -> System.delete_env("ARGUS_FLOWLOG_WORKERS") end)
    %{peer: peer}
  end

  test "a count is itself, whatever the inputs", %{peer: peer} do
    assert Peer.run(peer, fn -> {FlowLog.workers(3, 0), FlowLog.workers(1, 10_000_000_000)} end) ==
             {3, 1}
  end

  test "by default a small solve takes one worker, and a larger one a worker per 8 MB",
       %{peer: peer} do
    workers =
      Peer.run(peer, fn ->
        for mb <- [0, 1, 8, 9, 16, 17, 24, 1000],
            do: {mb, FlowLog.workers(:auto, mb * 1_000_000)}
      end)

    max = Peer.run(peer, &FlowLog.default_workers/0)

    assert workers ==
             for(
               {mb, n} <- [{0, 1}, {1, 1}, {8, 1}, {9, 2}, {16, 2}, {17, 3}, {24, 3}, {1000, 4}],
               do: {mb, min(n, max)}
             )
  end

  test "ARGUS_FLOWLOG_WORKERS names the count for every solve", %{peer: peer} do
    assert Peer.run(peer, fn ->
             System.put_env("ARGUS_FLOWLOG_WORKERS", "2")

             {FlowLog.workers(:auto, 0), FlowLog.workers(:auto, 10_000_000_000),
              FlowLog.workers(5, 0)}
           end) == {2, 2, 5}
  end
end
