defmodule Argus.Analyses.MessageContractTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.MessageContract, as: M

  @all [M.Mismatch, M.Agrees, M.CatchAll, M.StaleWrite]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp mods do
    assert {:ok, r} = Argus.analyze(@all, :message_contract)
    r |> Map.get("unhandled_self_message", []) |> Enum.map(&hd/1)
  end

  defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

  test "a tag the module sends itself and cannot handle is reported" do
    skip_without_souffle()
    assert named?(mods(), "MessageContract.Mismatch")
  end

  test "halves that agree are silent" do
    skip_without_souffle()
    refute named?(mods(), "MessageContract.Agrees")
  end

  test "a catch-all means no tag can fail" do
    skip_without_souffle()
    refute named?(mods(), "MessageContract.CatchAll")
  end

  test "an unrelated atom near a cast is not attributed to it" do
    skip_without_souffle()

    # The shape that made the first version unsound. It scanned backwards
    # for the last write to {x,1} and found GenServer.reply's `:ok`,
    # reporting :amqp_channel as casting :ok. def_use names the write that
    # actually reaches the call, and here the message is a parameter, so
    # there is no literal to attribute at all.
    refute named?(mods(), "MessageContract.StaleWrite")
  end
end
