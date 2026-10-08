defmodule Argus.Analyses.MailboxMessageTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.MessageContract, as: M
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @all [M.Mismatch, M.Agrees, M.CatchAll, M.StaleWrite, M.Forwarder, M.Sink]

  # Every test reads the same solve of @all: solved once, read-only.
  setup_all do
    %{solved: Memo.analyze(@all, :mailbox)}
  end

  defp mods(%{solved: solved}) do
    assert {:ok, r} = solved

    r
    |> Rows.where(:mailbox, "reply_defect", kind: ~w(unhandled_call unhandled_cast))
    |> Enum.map(&hd/1)
  end

  test "only a tag the module sends itself and cannot handle is reported", ctx do
    assert Enum.uniq(mods(ctx)) == [inspect(M.Mismatch)]

    # Silent:
    #   * Agrees: its halves agree.
    #   * CatchAll: a catch-all means no tag can fail.
    #   * StaleWrite: an unrelated atom near a cast is not attributed to
    #     it. The shape that made the first version unsound: it scanned
    #     backwards for the last write to {x,1} and found
    #     GenServer.reply's `:ok`, reporting :amqp_channel as casting :ok.
    #     def_use names the write that reaches the call, and here the
    #     message is a parameter, so there is no literal to attribute.
    #   * Forwarder: it calls the Sink it started with :sweep; Sink names
    #     no tag, so only points-to says the call is not Forwarder's own,
    #     and the call is that server's business.
  end
end
