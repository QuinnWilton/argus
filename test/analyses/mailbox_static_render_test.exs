defmodule Argus.Analyses.MailboxStaticRenderTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Mailbox
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.StaticRender
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    StaticRender.Subscribes,
    StaticRender.Ticks,
    StaticRender.Guarded,
    StaticRender.AskedElsewhere,
    StaticRender.Component,
    StaticRender.EventOnly,
    StaticRender.EndpointSubscribes,
    StaticRender.Adversarial.ElseArm,
    StaticRender.Adversarial.Unless,
    [StaticRender.Adversarial.HelperOnFalseArm, StaticRender.Topics],
    [StaticRender.Adversarial.HelperBothSides, StaticRender.MoreTopics],
    StaticRender.Adversarial.HandedAfterJoin,
    [StaticRender.Adversarial.NamedEndpoint, StaticRender.Endpoint]
  ]

  setup_all do
    %{batch: Batch.solve(:mailbox, [@batched])}
  end

  # `{entry, function, kind}`, the fixture prefix dropped.
  defp registrations(%{batch: batch}, modules) do
    assert {:ok, results} = Batch.analyze(batch, List.wrap(modules))
    short = &String.replace(&1, "Argus.Test.Fixtures.StaticRender.", "")

    for [_mod, entry, func, _site, kind] <-
          Rows.where(results, :mailbox, "static_render_registration", []) do
      {short.(entry), short.(func), kind}
    end
    |> Enum.sort()
  end

  describe "static_render_registration" do
    @describetag :flowlog

    test "a subscription in mount/3 with no connected? test (livebook before a05d6c5)", ctx do
      assert registrations(ctx, StaticRender.Subscribes) == [
               {"Subscribes:mount/3", "Subscribes:mount/3", "subscribe"}
             ]
    end

    test "an interval armed in mount/3 (Logflare before ec7331b)", ctx do
      assert registrations(ctx, StaticRender.Ticks) == [
               {"Ticks:mount/3", "Ticks:mount/3", "timer"}
             ]
    end

    test "a subscription through the socket's endpoint, an apply", ctx do
      assert registrations(ctx, StaticRender.EndpointSubscribes) == [
               {"EndpointSubscribes:mount/3", "EndpointSubscribes:mount/3", "subscribe"}
             ]
    end

    test "the nearest shapes to each quieting condition still register", ctx do
      for {modules, func} <- [
            {[StaticRender.Adversarial.ElseArm], "Adversarial.ElseArm:mount/3"},
            {[StaticRender.Adversarial.Unless], "Adversarial.Unless:mount/3"},
            {[StaticRender.Adversarial.HelperOnFalseArm, StaticRender.Topics],
             "Topics:subscribe_all/0"},
            {[StaticRender.Adversarial.HelperBothSides, StaticRender.MoreTopics],
             "MoreTopics:subscribe_all/0"},
            {[StaticRender.Adversarial.NamedEndpoint, StaticRender.Endpoint],
             "Adversarial.NamedEndpoint:mount/3"}
          ] do
        assert Enum.any?(registrations(ctx, modules), &(elem(&1, 1) == func)),
               "#{inspect(modules)} registers in #{func}"
      end

      assert [{_, "Adversarial.HandedAfterJoin:-mount/3-fun-0-/" <> _, "subscribe"}] =
               registrations(ctx, [StaticRender.Adversarial.HandedAfterJoin])
    end

    test "behind connected?/1, in the callback or around the call into a helper", ctx do
      assert registrations(ctx, StaticRender.Guarded) == []
    end

    test "a connected? test that decides something else guards nothing", ctx do
      assert registrations(ctx, StaticRender.AskedElsewhere) == [
               {"AskedElsewhere:mount/3", "AskedElsewhere:subscribe_all/0", "subscribe"}
             ]
    end

    test "a LiveComponent's update/2 monitoring; a handle_event/3 is connected only", ctx do
      assert registrations(ctx, StaticRender.Component) == [
               {"Component:update/2", "Component:update/2", "monitor"}
             ]

      assert registrations(ctx, StaticRender.EventOnly) == []
    end
  end

  describe "static_render_registration prose" do
    test "the title names neither the callback nor the topic" do
      finding =
        Mailbox.finding(:static_render_registration, [
          "M",
          "M:mount/3",
          "M:subscribe/0",
          "M:subscribe/0#4",
          "subscribe"
        ])

      assert finding.severity == :warning
      refute finding.title =~ "mount"
      assert finding.detail =~ "M.subscribe/0 subscribes it to a topic"
      assert [%{label: "the callback that reaches it"}] = finding.related
    end
  end
end
