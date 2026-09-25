defmodule Argus.Analyses.MailboxInfoTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Memo.analyze(modules, :mailbox)
    results
  end

  defp partial(results, source),
    do:
      Rows.where(results, :mailbox, "partial_handler",
        source: source,
        drop: [:source, :missing, :detail]
      )

  describe "partial_handler: late_message" do
    test "a partial handle_info with a late-message source is a note, GenStage included" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.PartialInfoServer,
          Argus.Test.Fixtures.TotalInfoServer,
          Argus.Test.Fixtures.PartialInfoStage,
          Argus.Test.Fixtures.QuietPartialInfoServer,
          Argus.Test.Fixtures.AppliesPartialInfoServer,
          Argus.Test.Fixtures.SelfSendPartialInfoServer,
          Argus.Test.Fixtures.MonitorsWithoutCatchall,
          Argus.Test.Fixtures.HandledTimerServer,
          Argus.Test.Fixtures.TaskTimerPartialInfoServer,
          Argus.Test.Fixtures.InlineOrTaskPartialInfoServer,
          Argus.Test.Fixtures.TaggedTimerServer
        ])

      partial = Enum.map(partial(results, "late_message"), fn [mod, _f] -> mod end) |> Enum.sort()

      assert partial == [
               "Argus.Test.Fixtures.AppliesPartialInfoServer",
               "Argus.Test.Fixtures.InlineOrTaskPartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoStage",
               "Argus.Test.Fixtures.SelfSendPartialInfoServer"
             ]

      # The monitoring module keeps its warning-grade finding, not this one.
      assert Enum.map(partial(results, "runtime"), fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end
  end

  describe "partial_handler: late_message sources" do
    alias Argus.Test.Fixtures.LateMessage, as: L

    test "a fun a callback is handed is a source; a closure, a timed call, a library's handler are not" do
      skip_without_souffle()

      # WarmerMacro is left out: the macro is a library's.
      results =
        analyze([L.Warmer, L.HandsClosure, L.TimedCall, L.StartTimer, L.RunsSentFun])

      assert Enum.map(partial(results, "late_message"), fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.LateMessage.RunsSentFun"]
    end

    test "a handler the program's own macro wrote is the program's" do
      skip_without_souffle()

      results = analyze([L.Warmer, L.WarmerMacro])

      assert Enum.map(partial(results, "late_message"), fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.LateMessage.Warmer"]
    end

    test "a library's handler is its own under every source, the program's own macro's is not" do
      skip_without_souffle()

      # The macros are left out: they are a library's.
      results = analyze([L.MonitorsInMacro, L.NolinkInMacro])
      assert partial(results, "runtime") == []
      assert partial(results, "task_nolink") == []

      results = analyze([L.MonitorsInMacro, L.MonitorMacro, L.NolinkInMacro, L.NolinkMacro])

      assert Enum.map(partial(results, "runtime"), fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.LateMessage.MonitorsInMacro"]

      assert partial(results, "task_nolink") |> Enum.map(&hd/1) |> Enum.uniq() ==
               ["Argus.Test.Fixtures.LateMessage.NolinkInMacro"]
    end

    test "a start_timer's 3-tuple is not the idle :timeout; a captured or mixed fun is unseen" do
      skip_without_souffle()

      results = analyze([L.StartTimerIdle, L.CallsInClosure, L.HandsMixed])

      assert partial(results, "late_message") |> Enum.map(fn [mod, _f] -> mod end) |> Enum.sort() ==
               [
                 "Argus.Test.Fixtures.LateMessage.CallsInClosure",
                 "Argus.Test.Fixtures.LateMessage.HandsMixed",
                 "Argus.Test.Fixtures.LateMessage.StartTimerIdle"
               ]
    end

    test "the logger's own machinery is no source, though it applies its handlers" do
      skip_without_souffle()

      results = analyze([L.LogsOnTick, :logger, :logger_backend])
      assert partial(results, "late_message") == []
    end
  end

  describe "partial_handler: runtime" do
    test "a monitoring GenServer with only a :DOWN clause is reported" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.MonitorsWithoutCatchall,
          Argus.Test.Fixtures.MonitorsWithCatchall
        ])

      mods = Enum.map(partial(results, "runtime"), fn [mod, _f] -> mod end)

      assert mods == ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end

    test "a monitor taken in a client function, in the caller's process, is not the server's" do
      skip_without_souffle()
      results = analyze([Argus.Test.Fixtures.ClientMonitorsServer])
      assert partial(results, "runtime") == []
    end

    test "a missing :EXIT clause is reported once, as the specific finding" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.TrapsWithoutExitClause])

      assert partial(results, "runtime") == []
    end
  end
end
