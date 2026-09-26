defmodule Argus.Analyses.ShutdownDrainTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Shutdown
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.Drain
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Drain.CancelsOnly,
    Drain.Flagged,
    Drain.OtherField,
    Drain.FlagUnread,
    Drain.CounterReset,
    Drain.NoCancel
  ]

  setup_all do
    %{batch: Batch.solve(:shutdown, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp drains(%{batch: batch}, module) do
    assert {:ok, results} = Batch.analyze(batch, [module])

    for [mod, _drain, gate, key] <- Rows.where(results, :shutdown, "drain_keeps_fetching", []) do
      {String.replace(mod, "Argus.Test.Fixtures.Drain.", ""),
       String.replace(gate, "Argus.Test.Fixtures.Drain.", ""), key}
    end
  end

  describe "drain_keeps_fetching" do
    test "a drain that clears the field the fetch waits on (broadway_sqs before 5b8f18a)", ctx do
      skip_without_souffle()

      assert drains(ctx, Drain.CancelsOnly) == [
               {"CancelsOnly", "CancelsOnly:handle_receive_messages/1", ":receive_timer"}
             ]
    end

    test "a draining flag the fetch can take closes it", ctx do
      skip_without_souffle()

      assert drains(ctx, Drain.Flagged) == []
    end

    test "a flag never read, a counter demand undoes, a drain that does not cancel still fetch",
         ctx do
      skip_without_souffle()

      for module <- [Drain.FlagUnread, Drain.CounterReset, Drain.NoCancel] do
        assert [{_, _, ":receive_timer"}] = drains(ctx, module), inspect(module)
      end
    end

    test "a cleared field no fetch tests opens nothing", ctx do
      skip_without_souffle()

      assert drains(ctx, Drain.OtherField) == []
    end
  end

  describe "drain_keeps_fetching prose" do
    test "the title names neither the producer nor the field" do
      finding =
        Shutdown.finding(:drain_keeps_fetching, [
          "P",
          "P:prepare_for_draining/1",
          "P:fetch/1",
          ":receive_timer"
        ])

      assert finding.severity == :warning
      refute finding.title =~ "receive_timer"
      assert finding.detail =~ ":receive_timer"
    end
  end
end
