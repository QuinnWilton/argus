defmodule Argus.Analyses.MailboxUnreceivedTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.Mailbox
  alias Argus.Test.Fixtures.UnreceivedMessage, as: U
  alias Argus.Test.Memo

  @all [
    U.Shop,
    U.Cart,
    U.Audit,
    U.Tagged,
    U.Taken,
    U.CatchAll,
    U.Helper,
    U.Closure,
    U.TwoPhase,
    U.EntersLoop,
    U.Variable,
    U.Server
  ]

  defp rows do
    {:ok, results} = Memo.analyze(@all, :mailbox)

    for [mod, func, _site, message, runs, starter, _spawn, _recv] <-
          results["unreceived_message"] do
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

  test "a receive in a helper the spawned function calls is judged too" do
    assert {"Helper", "Helper:start/0", ":unknown", "Helper:run/0", "Helper:start/0"} in rows()

    assert Enum.any?(
             rows(),
             &match?({"Closure", "Closure:start/0", ":tock", _, "Closure:start/0"}, &1)
           )
  end

  test "the send by name to a loop that takes it, and every quiet neighbour, are quiet" do
    found = rows()
    assert length(found) == 4, inspect(found)
    refute Enum.any?(found, fn {_, _, message, _, _} -> message == ":checkout" end)
    # TwoPhase's loop takes :work after run takes :go; EntersLoop hands its
    # mailbox to gen_server callbacks.
    refute Enum.any?(found, fn {mod, _, _, _, _} -> mod in ["TwoPhase", "EntersLoop"] end)
  end

  test "a state's list of subscribers and its worker are different processes" do
    # Relay sends :event to its first subscriber and :flush to the worker
    # it spawned; with the state one bag of pids, :event "reached" the
    # worker, whose receive takes only :flush.
    mods =
      for m <- [Relay, Subscriber], do: Module.concat(Argus.Test.Fixtures.PidFlow, m)

    {:ok, results} = Memo.analyze(mods, :mailbox)
    assert results["unreceived_message"] == []
  end

  @tag flowlog: false
  test "the finding anchors at the send and relates the receive and the spawn" do
    f =
      Mailbox.finding(:unreceived_message, [
        "Shop",
        "Shop:checkout/1",
        "Shop:checkout/1#13",
        ":checked_out",
        "Audit:loop/0",
        "Shop:start/0",
        "Shop:start/0#9",
        "Audit:loop/0#6"
      ])

    assert f.severity == :warning
    assert f.title == "Message sent to a process whose receive never takes it"
    assert f.at_label == ":checked_out is sent here"

    assert Enum.map(f.related, & &1.label) == [
             "a receive it never matches",
             "the process is spawned here"
           ]

    assert Enum.any?(f.help, &String.contains?(&1, "add a clause for :checked_out"))
    assert f.detail =~ "Shop.checkout/1 sends :checked_out"

    # loop_rec has no line, so the bytecode puts the receive frame on
    # `def loop do`; the source fragment carries it to the receive.
    assert [%{at_source: "receive", to_block: :receive}, spawn] = f.related
    # The spawn frame points at the spawn itself, not at its function.
    assert %Argus.InstrId{func: "start", idx: 9} = spawn.instr
  end
end
