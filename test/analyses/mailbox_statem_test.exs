defmodule Argus.Analyses.MailboxStatemTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :mailbox)
    results
  end

  defp statem_info(results),
    do:
      Rows.where(results, :mailbox, "partial_handler",
        source: "statem_info",
        drop: [:source, :missing]
      )

  defp statem_timeouts(results),
    do:
      Rows.where(results, :mailbox, "partial_handler",
        source: "statem_timeout",
        drop: [:source, :detail]
      )

  describe "partial_handler: statem_info" do
    test "the state without an :info catch-all is reported when its siblings have one" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.AsymmetricInfoStatem])

      assert [[mod, site, "ready"]] = statem_info(results)
      assert mod =~ "AsymmetricInfoStatem"
      assert site =~ "AsymmetricInfoStatem:ready/3"
    end

    test "a machine whose every state has the catch-all is clean" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.SymmetricInfoStatem])

      assert statem_info(results) == []
    end
  end

  describe "partial_handler: statem_timeout" do
    test "a {:timeout, ...} action matched as :info is reported" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.TimeoutMismatchStatem])

      assert [[mod, "handle_event", "event_timeout"]] = statem_timeouts(results)
      assert mod =~ "TimeoutMismatchStatem"
    end

    test "a handled timeout, and a state_timeout matched by its own state, are clean" do
      skip_without_souffle()

      results =
        analyze([Argus.Test.Fixtures.TimeoutHandledStatem, Argus.Test.Fixtures.TimeoutStatem])

      assert statem_timeouts(results) == []
    end

    test "a generic timeout handled as :timeout is reported; a {:timeout, name} head is not" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.GenericTimeoutMismatchStatem,
          Argus.Test.Fixtures.GenericTimeoutHandledStatem
        ])

      assert [[mod, "handle_event", "generic_timeout"]] = statem_timeouts(results)
      assert mod =~ "GenericTimeoutMismatchStatem"
    end
  end

  describe "reply_defect: statem_unreplied" do
    test "only the clause that returns bare :keep_state_and_data without replying is reported" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.UnrepliedCallStatem, Argus.Test.Fixtures.PendingCallStatem],
                 :mailbox
               )

      rows =
        Rows.where(results, :mailbox, "reply_defect",
          kind: "statem_unreplied",
          drop: [:kind, :tag]
        )

      assert [[_mod, "Argus.Test.Fixtures.UnrepliedCallStatem:disconnected/3", _site]] = rows
    end
  end
end
