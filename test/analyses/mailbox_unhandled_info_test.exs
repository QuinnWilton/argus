defmodule Argus.Analyses.MailboxUnhandledInfoTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Mailbox
  alias Argus.Test.Fixtures.UnhandledInfo, as: U
  alias Argus.Test.Memo

  @all [
    U.MemoryCheck,
    U.Reconnect,
    U.Listeners,
    U.Repair,
    U.Ticker,
    U.Pinger,
    U.PingServer,
    U.EnvelopeCaster,
    U.EnvelopeServer,
    U.Handled,
    U.Delegates,
    U.OpenClause,
    U.WaitsForDown,
    U.Flushes,
    U.Client,
    U.Poller,
    U.PollerTakes,
    U.Retry,
    U.WarmUp,
    U.Unjudged,
    U.TerminateWaits,
    U.TaskReceives,
    U.TickArity,
    U.MixedCatchAll
  ]

  setup_all do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Memo.analyze(@all, :mailbox)
    short = &String.replace(&1, "Argus.Test.Fixtures.UnhandledInfo.", "")

    rows =
      for [_mod, func, _site, message, source, server, _handler, fallback] <-
            results["unhandled_info"],
          do: {short.(func), message, source, short.(server), fallback}

    %{rows: rows, results: results}
  end

  test "a timer the server arms for itself with no clause for it is a crash", %{rows: rows} do
    assert {"MemoryCheck:schedule_memory_check/0", ":memory_check", "timer", "MemoryCheck",
            "crash"} in rows

    assert {"Reconnect:schedule_connect/0", ":connect", "timer", "Reconnect", "crash"} in rows
  end

  test "a gen envelope sent by hand is a call or a cast, not a message", %{rows: rows} do
    sent = for {"EnvelopeCaster:run/0", message, "send", _, _} <- rows, do: message
    assert sent == ["{:refresh_now, …}"]
  end

  test "a monitor's :DOWN a catch-all drops", %{rows: rows} do
    assert {"Listeners:handle_call/3", "{:DOWN, …}", "monitor", "Listeners", "catch_all"} in rows
  end

  test "a timer message a logging catch-all takes, and one GenServer's default takes",
       %{rows: rows} do
    assert {"Repair:init/1", ":repair", "timer", "Repair", "catch_all"} in rows
    assert {"Ticker:init/1", ":tick", "send", "Ticker", "default"} in rows
  end

  test "a catch-all after a clause a `use` put first is the module's own", %{rows: rows} do
    assert {"MixedCatchAll:init/1", ":stray", "timer", "MixedCatchAll", "catch_all"} in rows
  end

  test "a send points-to follows to another module's server", %{rows: rows} do
    assert {"Pinger:run/0", ":ping", "send", "PingServer", "crash"} in rows
  end

  test "a gen_statem no state of which takes a message it is sent", %{rows: rows} do
    assert {"Poller:init/1", ":poll", "timer", "Poller", "state_crash"} in rows
  end

  test "a literal tuple, and one the site builds, are told apart by their tag", %{rows: rows} do
    assert {"Retry:init/1", "{:retry, 3}", "timer", "Retry", "crash"} in rows
    assert {"Retry:handle_info/2", "{:backoff, …}", "timer", "Retry", "crash"} in rows
  end

  test "a receive in a closure a Task runs is the Task's, not the server's", %{rows: rows} do
    assert {"TaskReceives:init/1", ":tick", "timer", "TaskReceives", "crash"} in rows
  end

  test "a timer whose tag a clause takes in another shape is not taken", %{rows: rows} do
    assert {"TickArity:init/1", "{:tick, 1, :slow}", "timer", "TickArity", "crash"} in rows
    assert {"TickArity:init/1", "{:tick, …}", "timer", "TickArity", "crash"} in rows
    refute Enum.any?(rows, &match?({_, "{:tock, :fast}", _, _, _}, &1))
  end

  test "exactly those, and every quiet neighbour quiet", %{rows: rows} do
    assert length(rows) == 14, inspect(rows, pretty: true)

    quiet =
      ~w(Handled Delegates OpenClause WaitsForDown Flushes Client PollerTakes WarmUp Unjudged
         TerminateWaits)

    refute Enum.any?(rows, fn {_, _, _, server, _} -> server in quiet end)
  end

  test "partial_handler steps aside for the module a crash names", %{results: results} do
    mods = for [mod | _] <- results["partial_handler"], do: mod
    refute Enum.any?(mods, &String.ends_with?(&1, ".Reconnect"))
    refute Enum.any?(mods, &String.ends_with?(&1, ".MemoryCheck"))
  end

  describe "finding" do
    test "names the message, where it comes from and what takes it instead" do
      crash =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:schedule/0",
          "Mod:schedule/0#3",
          ":tick",
          "timer",
          "Mod",
          "Mod:handle_info/2",
          "crash"
        ])

      # A timer the program arms crashes the server with nothing else
      # needed: :error, as a call with a tag the server cannot take is.
      assert crash.severity == :error
      assert crash.title == "No handle_info/2 clause for a message the server is sent"

      down_crash =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:handle_call/3",
          "Mod:handle_call/3#5",
          "{:DOWN, …}",
          "monitor",
          "Mod",
          "Mod:handle_info/2",
          "crash"
        ])

      # A monitor's :DOWN comes only when the monitored process exits.
      assert down_crash.severity == :warning
      assert crash.detail =~ ":tick"
      assert crash.detail =~ "FunctionClauseError"

      down =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:handle_call/3",
          "Mod:handle_call/3#5",
          "{:DOWN, …}",
          "monitor",
          "Mod",
          "Mod:handle_info/2",
          "catch_all"
        ])

      assert down.severity == :warning
      assert down.title =~ "catch-all"
      assert Enum.any?(down.help, &(&1 =~ ":DOWN"))

      sent =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:init/1",
          "Mod:init/1#2",
          ":repair",
          "timer",
          "Mod",
          "Mod:handle_info/2",
          "catch_all"
        ])

      assert sent.severity == :info

      state =
        Mailbox.finding(:unhandled_info, [
          "Mod",
          "Mod:init/1",
          "Mod:init/1#2",
          ":poll",
          "timer",
          "Mod",
          "Mod:idle/3",
          "state_crash"
        ])

      assert state.title == "No clause for a message a gen_statem is sent"
      assert state.detail =~ ":info"
    end
  end
end
