defmodule Argus.Analyses.MailboxStatemTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Batch
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    Argus.Test.Fixtures.TimeoutMismatchStatem,
    Argus.Test.Fixtures.TimeoutHandledStatem,
    Argus.Test.Fixtures.TimeoutStatem,
    Argus.Test.Fixtures.GenericTimeoutMismatchStatem,
    Argus.Test.Fixtures.GenericTimeoutHandledStatem,
    Argus.Test.Fixtures.UnrepliedCallStatem,
    Argus.Test.Fixtures.PendingCallStatem,
    Argus.Test.Fixtures.CatchAllCallStatem,
    Argus.Test.Fixtures.StoppingEnterStatem,
    Argus.Test.Fixtures.NoEnterCallsStatem,
    Argus.Test.Fixtures.StructEnterStatem,
    Argus.Test.Fixtures.KeyEnterStatem
  ]

  setup_all do
    %{batch: Batch.solve(:mailbox, [@batched])}
  end

  defp analyze(%{batch: batch}, modules) do
    assert {:ok, results} = Batch.analyze(batch, modules)
    results
  end

  defp statem_timeouts(results), do: Map.get(results, "unhandled_timeout", [])

  describe "unhandled_timeout" do
    test "a {:timeout, ...} action matched as :info is reported", ctx do
      results = analyze(ctx, [Argus.Test.Fixtures.TimeoutMismatchStatem])

      assert [[mod, "handle_event", "event_timeout"]] = statem_timeouts(results)
      assert mod =~ "TimeoutMismatchStatem"
    end

    test "a handled timeout, and a state_timeout matched by its own state, are clean", ctx do
      results =
        analyze(ctx, [Argus.Test.Fixtures.TimeoutHandledStatem, Argus.Test.Fixtures.TimeoutStatem])

      assert statem_timeouts(results) == []
    end

    test "a generic timeout handled as :timeout is reported; a {:timeout, name} head is not",
         ctx do
      results =
        analyze(ctx, [
          Argus.Test.Fixtures.GenericTimeoutMismatchStatem,
          Argus.Test.Fixtures.GenericTimeoutHandledStatem
        ])

      assert [[mod, "handle_event", "generic_timeout"]] = statem_timeouts(results)
      assert mod =~ "GenericTimeoutMismatchStatem"
    end
  end

  describe "reply_defect: statem_unreplied" do
    test "only the clause that returns bare :keep_state_and_data without replying is reported",
         ctx do
      assert {:ok, results} =
               Batch.analyze(ctx.batch, [
                 Argus.Test.Fixtures.UnrepliedCallStatem,
                 Argus.Test.Fixtures.PendingCallStatem
               ])

      rows =
        Rows.where(results, :mailbox, "reply_defect",
          kind: "statem_unreplied",
          drop: [:kind]
        )

      # The tag is what names the clause in the source: the pattern tests
      # a bytecode anchor lands on carry the previous clause's line.
      assert [[_mod, "Argus.Test.Fixtures.UnrepliedCallStatem:disconnected/3", _site, ":cancel"]] =
               rows
    end

    test "a call no clause expects falls to a catch-all, not the clause tested before it", ctx do
      rows = unreplied(ctx, Argus.Test.Fixtures.CatchAllCallStatem)

      assert [
               ["Argus.Test.Fixtures.CatchAllCallStatem:logging/3", ""],
               ["Argus.Test.Fixtures.CatchAllCallStatem:sharing/3", ":get"],
               ["Argus.Test.Fixtures.CatchAllCallStatem:sharing/3", "_"],
               ["Argus.Test.Fixtures.CatchAllCallStatem:waiting/3", "_"]
             ] = Enum.sort(rows)
    end

    test "a state whose every enter call stops takes no call; one that may stay does", ctx do
      assert [["Argus.Test.Fixtures.StoppingEnterStatem:draining/3", "_"]] =
               unreplied(ctx, Argus.Test.Fixtures.StoppingEnterStatem)

      assert [["Argus.Test.Fixtures.NoEnterCallsStatem:closed/3", "_"]] =
               unreplied(ctx, Argus.Test.Fixtures.NoEnterCallsStatem)
    end

    test "an enter clause that names the machine's own struct still always stops", ctx do
      assert unreplied(ctx, Argus.Test.Fixtures.StructEnterStatem) == []
    end

    test "an enter clause that stops only on a key the data may lack does not always stop",
         ctx do
      assert [["Argus.Test.Fixtures.KeyEnterStatem:closed/3", _tag]] =
               unreplied(ctx, Argus.Test.Fixtures.KeyEnterStatem)
    end

    test "an untested clause is placed at its own line, else at its function", ctx do
      assert {:ok, results} = Batch.analyze(ctx.batch, [Argus.Test.Fixtures.CatchAllCallStatem])

      findings =
        results
        |> Rows.where(:mailbox, "reply_defect", kind: "statem_unreplied")
        |> Map.new(fn [_mod, func, _site, _kind, _tag] = row ->
          {func, Argus.Analyses.Mailbox.finding(:reply_defect, row)}
        end)

      waiting = findings["Argus.Test.Fixtures.CatchAllCallStatem:waiting/3"]
      assert waiting.instr == nil
      assert waiting.mfa == {Argus.Test.Fixtures.CatchAllCallStatem, :waiting, 3}

      logging = findings["Argus.Test.Fixtures.CatchAllCallStatem:logging/3"]
      assert %Argus.InstrId{func: "logging"} = logging.instr
    end
  end

  defp unreplied(ctx, module) do
    assert {:ok, results} = Batch.analyze(ctx.batch, [module])

    results
    |> Rows.where(:mailbox, "reply_defect", kind: "statem_unreplied", drop: [:kind])
    |> Enum.map(fn [_mod, func, _site, tag] -> [func, tag] end)
  end
end
