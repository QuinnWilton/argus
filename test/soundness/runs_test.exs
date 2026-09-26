defmodule Argus.Soundness.RunsTest do
  @moduledoc """
  The readings that narrow what runs again and what a gen_statem takes
  (docs/design/runs.md), each with the adversarial shapes it must not
  excuse: every program is solved alone and must keep its finding
  (`Argus.Test.Soundness`).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Runs, as: R

  defp refute_fires(modules, module) do
    found = fired(modules, :mailbox)

    refute Enum.any?(found, &match?({_, _, {^module, _, _}}, &1)),
           "expected no finding on #{inspect(module)} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  # The gen_statem extractor's two readings that narrow "No clause for a
  # message a gen_statem is sent": a function an event is re-dispatched to
  # is a state when a transition names it, and a clause that reaches a
  # call has passed its head.
  @statem {:error, "No clause for a message a gen_statem is sent"}

  defp assert_statem(module, mfa) do
    {severity, title} = @statem
    found = fired([module], :mailbox)

    assert {severity, title, mfa} in found,
           "expected #{inspect({severity, title, mfa})} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  describe "a call ends a clause's head: what comes before it still decides" do
    test "an :info clause that takes one message, then calls" do
      assert_statem(R.StatemContentThenCall, {R.StatemContentThenCall, :init, 1})
    end

    test "a catch-all for casts alone" do
      assert_statem(R.StatemCastCatchAll, {R.StatemCastCatchAll, :init, 1})
    end

    test "a generic clause guarded on the event type" do
      assert_statem(R.StatemGuardedCall, {R.StatemGuardedCall, :init, 1})
    end

    test "quiet: a clause that hands every event on and cases on the answer" do
      refute_fires([R.StatemDelegatingCatchAll], R.StatemDelegatingCatchAll)
    end
  end

  describe "a re-dispatched function is a state only when a transition names it" do
    test "a helper no transition names" do
      assert_statem(R.StatemHelperNotNamed, {R.StatemHelperNotNamed, :init, 1})
    end

    test "a helper whose name the module writes as a message" do
      assert_statem(R.StatemHelperNamedAsMessage, {R.StatemHelperNamedAsMessage, :init, 1})
    end

    test "a function handed the data first" do
      assert_statem(R.StatemDataFirst, {R.StatemDataFirst, :init, 1})
    end

    test "a state whose clauses return through a helper is judged too" do
      assert_statem(R.StatemViaHelper, {R.StatemViaHelper, :init, 1})
    end

    test "quiet: a named state an event is re-dispatched to takes the message" do
      refute_fires([R.StatemRedispatchedState], R.StatemRedispatchedState)
    end
  end
end
