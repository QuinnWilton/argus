defmodule Argus.Analyses.MailboxResubscribeTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Mailbox
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.Resubscribe
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Resubscribe.Ticker,
    Resubscribe.Once,
    Resubscribe.DeviceList,
    Resubscribe.DeviceListFixed,
    [Resubscribe.Apps, Resubscribe.Session],
    [Resubscribe.Endpoint, Resubscribe.Channel],
    Resubscribe.UnsubscribesAtStop,
    Resubscribe.UnsubscribesElsewhere,
    [Resubscribe.HelperOfAnotherEntry, Resubscribe.Rooms],
    Resubscribe.Navigates,
    Resubscribe.OnceFromInit,
    Resubscribe.SentAgain,
    Resubscribe.OtherClause,
    Resubscribe.Rearmed,
    Resubscribe.StateChecked,
    Resubscribe.ScopeRestart,
    Resubscribe.StateAskedElsewhere,
    Resubscribe.MessageDecided,
    Resubscribe.StateMatchRaises,
    Resubscribe.HelperStateChecked,
    Resubscribe.HelperStateElsewhere
  ]

  setup_all do
    %{batch: Batch.solve(:mailbox, [@batched])}
  end

  # `{module, entry, function}`, the fixture prefix dropped.
  defp repeated(%{batch: batch}, modules) do
    assert {:ok, results} = Batch.analyze(batch, modules)
    short = &String.replace(&1, "Argus.Test.Fixtures.Resubscribe.", "")

    for [mod, entry, func, _site] <- Rows.where(results, :mailbox, "repeated_subscription", []) do
      {short.(mod), short.(entry), short.(func)}
    end
    |> Enum.sort()
  end

  describe "repeated_subscription" do
    @describetag :flowlog

    test "a server that subscribes on every tick; subscribing in init/1 is once", ctx do
      assert repeated(ctx, [Resubscribe.Ticker]) == [
               {"Ticker", "Ticker:handle_info/2", "Ticker:handle_info/2"}
             ]

      assert repeated(ctx, [Resubscribe.Once]) == []
    end

    test "re-subscribing through the socket's endpoint (nerves_hub_web before 59dd4c6)", ctx do
      assert [
               {"DeviceList", "DeviceList:handle_info/2",
                "DeviceList:-subscribe_all/1-fun-0-/" <> _}
             ] =
               repeated(ctx, [Resubscribe.DeviceList])

      assert repeated(ctx, [Resubscribe.DeviceListFixed]) == []
    end

    test "an unsubscribe that subscribes (livebook before 3e63097)", ctx do
      assert repeated(ctx, [Resubscribe.Apps, Resubscribe.Session]) == [
               {"Session", "Session:handle_event/3", "Apps:subscribe/1"},
               {"Session", "Session:handle_event/3", "Apps:unsubscribe/1"}
             ]
    end

    test "an endpoint's subscribe/1, named, from a channel's handle_in/3", ctx do
      rows = repeated(ctx, [Resubscribe.Endpoint, Resubscribe.Channel])
      assert {"Channel", "Channel:handle_in/3", "Channel:handle_in/3"} in rows
    end
  end

  describe "repeated_subscription, beside its quieting condition" do
    @describetag :flowlog

    test "an unsubscribe only at stop, in another callback or another entry's helper leaves it",
         ctx do
      assert [{"UnsubscribesAtStop", "UnsubscribesAtStop:handle_cast/2", _}] =
               repeated(ctx, [Resubscribe.UnsubscribesAtStop])

      assert [{"UnsubscribesElsewhere", "UnsubscribesElsewhere:handle_event/3", _}] =
               repeated(ctx, [Resubscribe.UnsubscribesElsewhere])

      assert {"HelperOfAnotherEntry", "HelperOfAnotherEntry:handle_info/2", "Rooms:subscribe/1"} in repeated(
               ctx,
               [Resubscribe.HelperOfAnotherEntry, Resubscribe.Rooms]
             )
    end

    test "a clause for a message sent once, from init/1, is not judged; one sent again is", ctx do
      assert repeated(ctx, [Resubscribe.OnceFromInit]) == []

      for module <- [Resubscribe.SentAgain, Resubscribe.Rearmed] do
        assert [{_, _, _}] = repeated(ctx, [module]), inspect(module)
      end

      assert [{"OtherClause", "OtherClause:handle_info/2", "OtherClause:handle_info/2"}] =
               repeated(ctx, [Resubscribe.OtherClause])
    end

    test "a callback that asks its own state first is not judged; the nearest shapes are", ctx do
      assert repeated(ctx, [Resubscribe.StateChecked]) == []
      assert repeated(ctx, [Resubscribe.ScopeRestart]) == []
      assert repeated(ctx, [Resubscribe.HelperStateChecked]) == []

      for module <- [
            Resubscribe.StateAskedElsewhere,
            Resubscribe.MessageDecided,
            Resubscribe.StateMatchRaises,
            Resubscribe.HelperStateElsewhere
          ] do
        assert [{_, _, _}] = repeated(ctx, [module]), inspect(module)
      end
    end

    test "a LiveView's handle_params/3, which live navigation runs again", ctx do
      assert [{"Navigates", "Navigates:handle_params/3", "Navigates:handle_params/3"}] =
               repeated(ctx, [Resubscribe.Navigates])
    end
  end

  describe "repeated_subscription prose" do
    test "the title names neither the topic nor the callback" do
      finding =
        Mailbox.finding(:repeated_subscription, ["M", "M:handle_info/2", "M:sub/1", "M:sub/1#3"])

      assert finding.severity == :warning
      refute finding.title =~ "handle_info"
      assert [%{label: "the callback that runs it again"}] = finding.related
    end
  end
end
