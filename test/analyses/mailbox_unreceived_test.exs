defmodule Argus.Analyses.MailboxUnreceivedTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Mailbox
  alias Argus.Test.Fixtures.UnreceivedMessage, as: U

  @all [
    U.Shop,
    U.Cart,
    U.Audit,
    U.Tagged,
    U.Taken,
    U.CatchAll,
    U.Helper,
    U.Variable,
    U.Server
  ]

  defp rows do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Argus.analyze(@all, :mailbox)

    for [mod, func, _site, message, runs, starter, _recv] <- results["unreceived_message"] do
      short = &String.replace(&1, "Argus.Test.Fixtures.UnreceivedMessage.", "")
      {short.(mod), short.(func), message, short.(runs), short.(starter)}
    end
  end

  test "a message followed through a parameter to a loop that never takes it" do
    assert {"Shop", "Shop:checkout/1", ":checked_out", "Audit:loop/0", "Shop:start/0"} in rows()
  end

  test "a tuple message to a loop that takes only atoms" do
    assert {"Tagged", "Tagged:start/0", "{:job, …}", "Tagged:loop/0", "Tagged:start/0"} in rows()
  end

  test "the send by name to a loop that takes it, and every quiet neighbour, are quiet" do
    found = rows()
    assert length(found) == 2, inspect(found)
    refute Enum.any?(found, fn {_, _, message, _, _} -> message == ":checkout" end)
  end

  test "the finding anchors at the send and relates the receive and the spawn" do
    f =
      Mailbox.finding(:unreceived_message, [
        "Shop",
        "Shop:checkout/1",
        "Shop:checkout/1#13",
        ":checked_out",
        "Audit:loop/0",
        "Shop:start/0",
        "Audit:loop/0#6"
      ])

    assert f.severity == :warning
    assert f.title == ":checked_out is sent to a process whose receive never takes it"
    assert f.at_label == "the message is sent here"

    assert Enum.map(f.related, & &1.label) == [
             "the receive it never matches",
             "the process is spawned here"
           ]

    assert Enum.any?(f.help, &String.contains?(&1, "add a clause for :checked_out"))
  end
end
