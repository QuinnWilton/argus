defmodule Argus.Soundness.GatedOnceTest do
  @moduledoc """
  "Once by the state" (clientlib/runs.dl's gated_once_site, Argus.Extractors.StateGate,
  docs/design/analysis-model.md#once-by-state), with the adversarial shapes each of its
  conditions must not excuse: every program is solved alone and must keep its finding
  (`Argus.Test.Soundness`).

  A GenServer handler's site runs at most once per incarnation when a
  test of a field of the state lets it run only for some atoms, every way
  the handler completes after it sets the field outside them (or ends the
  process), no return of the module sets the field back to one of them
  or to a value it does not show, and nothing in the program calls the
  handler. The observable is mailbox's monitor leak: each fixture takes a
  monitor whose ref it throws away behind such a test, reported exactly
  when the site may run again ("Monitor taken again with its ref thrown
  away"). The timer loop rule reads the same sites.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Gated, as: G

  @dropped {:info, "Monitor taken again with its ref thrown away"}
  @loop "Periodic timer loop armed again while it runs"

  defp assert_fires(modules, mfa) do
    {severity, title} = @dropped
    found = fired(modules, :mailbox)

    assert {severity, title, mfa} in found,
           "expected #{inspect({severity, title, mfa})} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  defp refute_fires(modules, module) do
    found = fired(modules, :mailbox)

    refute Enum.any?(found, &match?({_, _, {^module, _, _}}, &1)),
           "expected no finding on #{inspect(module)} in:\n" <>
             Enum.map_join(found, "\n", &inspect/1)
  end

  describe "the gate: the site runs only while a field of the state holds the atom" do
    test "the monitor comes before the test" do
      assert_fires([G.MonitorBeforeTest], {G.MonitorBeforeTest, :handle_cast, 2})
    end

    test "the test reads a field of a map the state holds" do
      assert_fires([G.NestedField], {G.NestedField, :handle_cast, 2})
    end

    test "the test reads Map.get/2's answer" do
      assert_fires([G.MapGet], {G.MapGet, :handle_cast, 2})
    end

    test "the head tests the message, not the state" do
      assert_fires([G.MessageField], {G.MessageField, :handle_cast, 2})
    end

    test "quiet: a boolean flag in the clause head" do
      refute_fires([G.Flag], G.Flag)
    end

    test "quiet: a nil check whose other arm raises" do
      refute_fires([G.NilOwner], G.NilOwner)
    end

    test "quiet: a status atom a case takes" do
      refute_fires([G.Status], G.Status)
    end

    test "quiet: an Erlang record's field in the head" do
      refute_fires([:gated_record], :gated_record)
    end
  end

  describe "closed: every way the handler completes after the site sets the field outside" do
    test "the return sets another field" do
      assert_fires([G.OtherField], {G.OtherField, :handle_cast, 2})
    end

    test "one way out hands the state back as it came" do
      assert_fires([G.SomeReturns], {G.SomeReturns, :handle_cast, 2})
    end

    test "a throw after the site, which gen_server takes as the result" do
      assert_fires([G.Throws], {G.Throws, :handle_cast, 2})
    end

    test "a catch that raises again what it took, in its own class" do
      assert_fires([G.RethrowsCaught], {G.RethrowsCaught, :handle_cast, 2})
    end

    test "a rescue that hands the state back as it came" do
      assert_fires([G.RescueKeeps], {G.RescueKeeps, :handle_cast, 2})
    end

    test "the field set to what the message carries" do
      assert_fires([G.MessageValue], {G.MessageValue, :handle_cast, 2})
    end

    test "quiet: closed through a helper the state is handed to" do
      refute_fires([G.ClosedByHelper], G.ClosedByHelper)
    end

    test "quiet: the process stops after the site" do
      refute_fires([G.ClosedByStop], G.ClosedByStop)
    end

    test "quiet: the field set to the caller from handle_call/3's from" do
      refute_fires([G.ClaimedByCaller], G.ClaimedByCaller)
    end
  end

  describe "no return of the module sets the field back" do
    test "a handler sets it back to the atom" do
      assert_fires([G.ResetInHandler], {G.ResetInHandler, :handle_cast, 2})
    end

    test "a call sets it to what it is handed" do
      assert_fires([G.ResetFromMessage], {G.ResetFromMessage, :handle_cast, 2})
    end

    test "a handler hands the state to a helper that clears it" do
      assert_fires([G.ResetThroughHelper], {G.ResetThroughHelper, :handle_cast, 2})
    end

    test "a handler returns what a helper returns, which clears it" do
      assert_fires([G.ResetByTailCall], {G.ResetByTailCall, :handle_cast, 2})
    end

    test "code_change/3 starts it over" do
      assert_fires([G.ResetInCodeChange], {G.ResetInCodeChange, :handle_cast, 2})
    end

    test "a call replaces the whole state" do
      assert_fires([G.StateReplaced], {G.StateReplaced, :handle_cast, 2})
    end

    test "an Erlang record's field a call sets back" do
      assert_fires([:gated_record_reset], {:gated_record_reset, :handle_cast, 2})
    end

    test "quiet: terminate/2 clears it on the way out" do
      refute_fires([G.ResetInTerminate], G.ResetInTerminate)
    end

    test "quiet: another handler clears another field" do
      refute_fires([G.OtherFieldReset], G.OtherFieldReset)
    end
  end

  describe "the handler runs only as the process's loop runs it" do
    test "another handler runs it with the field set back" do
      assert_fires([G.CalledWithFreshState], {G.CalledWithFreshState, :handle_cast, 2})
    end

    test "a client function runs it in its caller's process" do
      assert_fires([G.CalledByClient], {G.CalledByClient, :handle_cast, 2})
    end

    test "a handler hands it a state of its own making" do
      assert_fires([G.HandedOn], {G.HandedOn, :handle_cast, 2})
    end

    test "a server under a behaviour the alias table does not know" do
      assert_fires([G.UnderWrapper], {G.UnderWrapper, :handle_cast, 2})
    end
  end

  describe "a periodic loop a gated clause starts" do
    defp loop_fires?(module),
      do: Enum.any?(fired([module], :mailbox), &match?({_, @loop, {^module, _, _}}, &1))

    test "the field a handler sets back starts a second loop" do
      assert loop_fires?(G.LoopStartedAgain)
    end

    test "quiet: the field nothing sets back starts one loop" do
      refute loop_fires?(G.LoopStartedOnce)
    end
  end
end
