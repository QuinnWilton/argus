defmodule Argus.Analyses.MailboxStatemTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :mailbox)
    results
  end

  describe "state_missing_info_catchall" do
    test "the state without an :info catch-all is reported when its siblings have one" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.AsymmetricInfoStatem])

      assert [[mod, "ready", site]] = results["state_missing_info_catchall"]
      assert mod =~ "AsymmetricInfoStatem"
      assert site =~ "AsymmetricInfoStatem:ready/3"
    end

    test "a machine whose every state has the catch-all is clean" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.SymmetricInfoStatem])

      assert results["state_missing_info_catchall"] == []
    end
  end

  describe "statem_timeout_unhandled" do
    test "a {:timeout, ...} action matched as :info is reported" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.TimeoutMismatchStatem])

      assert [[mod, "event_timeout", "handle_event"]] = results["statem_timeout_unhandled"]
      assert mod =~ "TimeoutMismatchStatem"
    end

    test "a handled timeout, and a state_timeout matched by its own state, are clean" do
      skip_without_souffle()

      results =
        analyze([Argus.Test.Fixtures.TimeoutHandledStatem, Argus.Test.Fixtures.TimeoutStatem])

      assert results["statem_timeout_unhandled"] == []
    end

    test "a generic timeout handled as :timeout is reported; a {:timeout, name} head is not" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.GenericTimeoutMismatchStatem,
          Argus.Test.Fixtures.GenericTimeoutHandledStatem
        ])

      assert [[mod, "generic_timeout", "handle_event"]] = results["statem_timeout_unhandled"]
      assert mod =~ "GenericTimeoutMismatchStatem"
    end
  end

  describe "call_never_replied" do
    test "only the clause that returns bare :keep_state_and_data without replying is reported" do
      skip_without_souffle()

      assert {:ok, results} =
               Argus.analyze(
                 [Argus.Test.Fixtures.UnrepliedCallStatem, Argus.Test.Fixtures.PendingCallStatem],
                 :mailbox
               )

      rows = Map.get(results, "call_never_replied", [])

      assert [[_mod, "Argus.Test.Fixtures.UnrepliedCallStatem:disconnected/3", _site]] = rows
    end
  end
end
