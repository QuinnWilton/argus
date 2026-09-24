defmodule Argus.Analyses.MailboxMessageTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Fixtures.MessageContract, as: M
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @all [M.Mismatch, M.Agrees, M.CatchAll, M.StaleWrite, M.Forwarder, M.Sink]

  # Every test reads the same solve of @all: solved once, read-only.
  setup_all do
    %{solved: Memo.analyze(@all, :mailbox)}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp mods(%{solved: solved}) do
    assert {:ok, r} = solved
    r |> Rows.where(:mailbox, "reply_defect", kind: ~w(self_call self_cast)) |> Enum.map(&hd/1)
  end

  defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

  test "a tag the module sends itself and cannot handle is reported", ctx do
    skip_without_souffle()
    assert named?(mods(ctx), "MessageContract.Mismatch")
  end

  test "halves that agree are silent", ctx do
    skip_without_souffle()
    refute named?(mods(ctx), "MessageContract.Agrees")
  end

  test "a catch-all means no tag can fail", ctx do
    skip_without_souffle()
    refute named?(mods(ctx), "MessageContract.CatchAll")
  end

  test "an unrelated atom near a cast is not attributed to it", ctx do
    skip_without_souffle()

    # The shape that made the first version unsound. It scanned backwards
    # for the last write to {x,1} and found GenServer.reply's `:ok`,
    # reporting :amqp_channel as casting :ok. def_use names the write that
    # actually reaches the call, and here the message is a parameter, so
    # there is no literal to attribute at all.
    refute named?(mods(ctx), "MessageContract.StaleWrite")
  end

  test "a call points-to follows to another module's server is that server's business", ctx do
    skip_without_souffle()

    # Forwarder calls the Sink it started with :sweep; Sink names no tag,
    # so only points-to says the call is not Forwarder's own.
    refute named?(mods(ctx), "MessageContract.Forwarder")
  end
end
