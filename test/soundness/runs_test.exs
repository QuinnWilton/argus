defmodule Argus.Soundness.RunsTest do
  @moduledoc """
  The once/again split's narrowings (clientlib/runs.dl,
  docs/design/runs.md), each with the adversarial shapes it must not
  excuse: every program is solved alone and must keep its finding
  (`Argus.Test.Soundness`).

  A clause of a callback runs once per incarnation only when every
  message that can enter it is made by its process's once code: init/1,
  a Channel's join/3, a LiveView's mount/3, and the clauses those alone
  enter. The observable is mailbox's monitor leak: each fixture takes a
  monitor whose ref it throws away in such a clause, which is reported
  exactly when the clause runs again ("Monitor taken again with its ref
  thrown away"). The gen_statem extractor's readings of a machine's
  states keep "No clause for a message a gen_statem is sent".
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Runs, as: R

  @dropped {:info, "Monitor taken again with its ref thrown away"}

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

  describe "a message clause runs once only when once code alone sends what it takes" do
    test "a tag init/1 sends and a handler sends again" do
      assert_fires([R.FromInitAndHandler], {R.FromInitAndHandler, :handle_info, 2})
    end

    test "a tag init/1 sends and another process may send" do
      assert_fires([R.FromInitAndOutside], {R.FromInitAndOutside, :handle_info, 2})
    end

    test "two clauses that send each other round" do
      assert_fires([R.Cycle], {R.Cycle, :handle_info, 2})
    end

    test "a sender both init/1 and a cast reach" do
      assert_fires([R.SharedSender], {R.SharedSender, :handle_info, 2})
    end

    test "a handler that sends itself a message of any tag" do
      assert_fires([R.Relay], {R.Relay, :handle_info, 2})
    end

    test "an interval timer init/1 arms" do
      assert_fires([R.Interval], {R.Interval, :handle_info, 2})
    end

    test "a cast that runs the clause itself" do
      assert_fires([R.DirectCall], {R.DirectCall, :handle_info, 2})
    end

    test "a message a library the process subscribes through delivers" do
      assert_fires([R.Published], {R.Published, :handle_info, 2})
    end

    test "a clause another module runs directly" do
      assert_fires(
        [R.CalledFromOutside, R.OutsideCaller],
        {R.CalledFromOutside, :handle_info, 2}
      )
    end

    test "quiet: a tag only init/1 sends" do
      refute_fires([R.OnceOnly], R.OnceOnly)
    end

    test "quiet: a clause only a once clause's message enters" do
      refute_fires([R.OnceChain], R.OnceChain)
    end
  end

  describe "a handle_continue/2 clause runs once only when once code alone continues to it" do
    test "a continue init/1 and a handler return" do
      assert_fires([R.ContinueAgain], {R.ContinueAgain, :handle_continue, 2})
    end

    test "a continue a call returns through a helper" do
      assert_fires([R.ContinueFromHelper], {R.ContinueFromHelper, :handle_continue, 2})
    end

    test "a continue of any tag a handler returns" do
      assert_fires([R.ContinueAny], {R.ContinueAny, :handle_continue, 2})
    end

    test "quiet: a continue only init/1 returns" do
      refute_fires([R.ContinueOnce], R.ContinueOnce)
    end
  end

  describe "a gen_statem's :internal clause runs once only when once code alone inserts it" do
    test "an event init/1 and a cast insert" do
      assert_fires([R.InsertAgain], {R.InsertAgain, :handle_event, 4})
    end

    test "an event of a type a cast is handed" do
      assert_fires([R.InsertAnyType], {R.InsertAnyType, :handle_event, 4})
    end

    test "an inserting helper init/1 and a cast share" do
      assert_fires([R.InsertShared], {R.InsertShared, :handle_event, 4})
    end

    test "quiet: an event only init/1 inserts" do
      refute_fires([R.InsertOnce], R.InsertOnce)
    end

    # A clause is told by its event's content too (issue #3).
    test "quiet: an event only init/1 inserts, beside one a cast inserts for another clause" do
      refute_fires([R.InsertOnceBesideAnother], R.InsertOnceBesideAnother)
    end

    test "an event of a content a cast is handed" do
      assert_fires([R.InsertAnyContent], {R.InsertAnyContent, :handle_event, 4})
    end

    test "a clause for any content, which a cast's event of another content enters" do
      assert_fires([R.InsertIntoAnyContent], {R.InsertIntoAnyContent, :handle_event, 4})
    end
  end

  describe "the :timeout clause runs once only when once code alone arms the idle timeout" do
    test "a timeout init/1 and a cast arm" do
      assert_fires([R.TimeoutAgain], {R.TimeoutAgain, :handle_info, 2})
    end

    test "a timeout the return does not spell" do
      assert_fires([R.TimeoutUnspelled], {R.TimeoutUnspelled, :handle_info, 2})
    end

    test "a timeout a cast returns through a helper" do
      assert_fires([R.TimeoutFromHelper], {R.TimeoutFromHelper, :handle_info, 2})
    end

    test "quiet: a timeout only init/1 arms" do
      refute_fires([R.TimeoutOnce], R.TimeoutOnce)
    end
  end

  describe "a LiveView's handle_async/3 clause runs once only when once code alone starts it" do
    test "a task mount/3 and an event start" do
      assert_fires([R.AsyncAgain], {R.AsyncAgain, :handle_async, 3})
    end

    test "a task an event starts under any name" do
      assert_fires([R.AsyncAnyName], {R.AsyncAnyName, :handle_async, 3})
    end

    test "a starting helper mount/3 and a message share" do
      assert_fires([R.AsyncShared], {R.AsyncShared, :handle_async, 3})
    end

    test "quiet: a task only mount/3 starts" do
      refute_fires([R.AsyncOnce], R.AsyncOnce)
    end
  end

  describe "a producer no known root reaches counts where code off the call graph can run" do
    test "a fun another module builds, run by a call" do
      assert_fires([R.RunsFuns, R.FunSender], {R.RunsFuns, :handle_info, 2})
    end

    test "a hook module's export, run through the module the state names" do
      assert_fires([R.CallsHooks, R.Hooks], {R.CallsHooks, :handle_info, 2})
    end

    test "a behaviour's callback no table lists, for its own module's clauses" do
      assert_fires([R.ComponentUpdate], {R.ComponentUpdate, :handle_async, 3})
    end
  end

  describe "the timer loop and subscription rules read the split" do
    test "a subscription in a handle_continue/2 clause a handler continues to" do
      assert {:warning, "Subscription made again each time a callback runs",
              {R.ContinueResubscribes, :handle_continue, 2}} in fired(
               [R.ContinueResubscribes],
               :mailbox
             )
    end

    test "a second arm in a handle_continue/2 clause a handler continues to" do
      assert Enum.any?(
               fired([R.ContinueRearms], :mailbox),
               &match?(
                 {_, "Periodic timer loop armed again while it runs", {R.ContinueRearms, _, _}},
                 &1
               )
             )
    end

    test "quiet: a subscription in a clause only init/1 continues to" do
      refute_fires([R.SubscribesOnce], R.SubscribesOnce)
    end
  end

  describe "coupling: a request the start's continue chain makes, whatever else runs it again" do
    @coupled "Coupled children under one_for_one"

    defp coupled?(modules, sup),
      do: Enum.any?(fired(modules, :coupling), &match?({_, @coupled, {^sup, :init, 1}}, &1))

    test "a continue init/1 and a reconnect both return" do
      assert coupled?(
               [R.ContinueAlsoFromHandlerSup, R.Keeper, R.ContinueAlsoFromHandler],
               R.ContinueAlsoFromHandlerSup
             )
    end

    test "a continue the start's chain and a reconnect both return" do
      assert coupled?([R.ContinueChainSup, R.Keeper, R.ContinueChain], R.ContinueChainSup)
    end

    test "a chain of clauses the start's messages enter" do
      assert coupled?([R.ChainFromInitSup, R.Keeper, R.ChainFromInit], R.ChainFromInitSup)
    end

    test "quiet: a continue only a handler returns" do
      refute coupled?(
               [R.ContinueOnlyFromHandlerSup, R.Keeper, R.ContinueOnlyFromHandler],
               R.ContinueOnlyFromHandlerSup
             )
    end
  end

  describe "a clause function a callback hands its message to" do
    test "a clause of the shared function another of its clauses enters again" do
      assert_fires([R.DelegatingServer, R.Shared], {R.Shared, :handle_info, 2})
    end

    test "a clause the delegating server's own cast enters again" do
      assert_fires([R.DelegateResend, R.SharedB], {R.SharedB, :handle_info, 2})
    end

    test "a clause one of two delegating servers enters again" do
      assert_fires([R.OwnerOnce, R.OwnerAgain, R.SharedC], {R.SharedC, :handle_info, 2})
    end

    test "quiet: the shared function's clause only the start enters" do
      refute_fires([R.DelegatingOnce, R.SharedOnce], R.SharedOnce)
    end
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
