defmodule Argus.Analyses.FailureConsistencyTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Failure
  alias Argus.Souffle
  alias Argus.Test.Fixtures.Consistency, as: C
  alias Argus.Test.Memo

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows(modules) do
    {:ok, results} = Memo.analyze(modules, :failure)

    for [func, _site, callee, belief, agree, deviate, _target | _] <-
          results["inconsistent_handling"],
        do: {func, callee, belief, String.to_integer(agree), String.to_integer(deviate)}
  end

  describe "result_checked" do
    test "the one site that discards a result five others match is reported, with the counts" do
      skip_without_souffle()
      assert [{func, callee, "result_checked", 5, 1}] = rows([C.DeviantIgnore])
      assert func =~ "DeviantIgnore:f/2"
      assert callee =~ "DynamicSupervisor:start_child/2"
    end

    test "two agreeing sites are not a convention" do
      skip_without_souffle()
      assert rows([C.WeakBelief]) == []
    end

    test "three against three is a convention either way" do
      skip_without_souffle()
      assert rows([C.NoMajority]) == []
    end

    test "a callee outside the process APIs is not this analysis's business" do
      skip_without_souffle()
      assert rows([C.OutsideScope]) == []
    end

    test "a callee whose spec names no failure value has no result to check" do
      skip_without_souffle()
      assert rows([C.TotalCallee]) == []
    end

    test "a discarded start result is startup's finding, not reported here again" do
      skip_without_souffle()
      assert rows([C.StartIgnored]) == []

      {:ok, startup} = Memo.analyze([C.StartIgnored], :startup)
      assert [[func, "GenServer.start_link/3"]] = startup["ignored_start_result"]
      assert func =~ "StartIgnored:f/1"
    end

    test "a site that returns the result is neither agreeing nor deviant" do
      skip_without_souffle()
      assert rows([C.TailReturns]) == []
    end

    test "the population is the whole program, not the module" do
      skip_without_souffle()
      # WeakBelief's two checks join DeviantIgnore's five: seven against two.
      found = rows([C.DeviantIgnore, C.WeakBelief])
      assert length(found) == 2

      assert Enum.all?(found, fn
               {_, _, "result_checked", 7, 2} -> true
               _ -> false
             end)
    end
  end

  describe "exception_guarded" do
    test "the one bare call among four guarded ones is reported" do
      skip_without_souffle()
      assert [{func, callee, "exception_guarded", 4, 1}] = rows([C.DeviantBare])
      assert func =~ "DeviantBare:e/1"
      assert callee =~ "GenServer:call/2"
    end

    test "a send to a name elsewhere cannot fail; one to a local name can" do
      skip_without_souffle()
      assert rows([C.RemoteSends]) == []
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.LocalSends])
      assert func =~ "LocalSends:d/1"
    end

    test "an ETS call in the process that owns the table cannot fail on a missing table" do
      skip_without_souffle()
      assert rows([C.OwnerDeletes]) == []
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.ClientDeletes])
      assert func =~ "ClientDeletes:drop/1"
    end

    test "a lookup_element of a row the owner seeds and nothing removes cannot fail" do
      skip_without_souffle()
      assert rows([C.SeededRows]) == []
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.UnseededRows])
      assert func =~ "UnseededRows:methods/0"
    end

    test "a table the owner makes only when asked can be missing in the owner" do
      skip_without_souffle()
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.LazyOwner])
      assert func =~ "LazyOwner:handle_call/3"
    end

    test "a row seeded only when an option asks can be missing" do
      skip_without_souffle()
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.ConditionalSeed])
      assert func =~ "ConditionalSeed:d/0"
    end
  end

  describe "what guards a call" do
    test "a try whose handler takes nothing guards nothing" do
      skip_without_souffle()
      assert rows([C.AfterOnly]) == []
    end

    test "a handler that takes another class, or re-raises, guards nothing" do
      skip_without_souffle()
      assert rows([C.WrongClass]) == []
    end

    test "a handler that raises what it caught again guards nothing" do
      skip_without_souffle()
      assert rows([C.ReraiseOnly]) == []
    end

    test "a site under a try that lets the call's class through is the deviant" do
      skip_without_souffle()
      assert [{func, callee, "exception_guarded", 3, 1}] = rows([C.HiddenDeviant])
      assert func =~ "HiddenDeviant:d/1"
      assert callee =~ "update_counter/3"
    end

    test "Erlang's catch takes every class" do
      skip_without_souffle()
      # `ec`: three `catch` sites and a bare one; `mx`: three try sites and
      # one `catch`, all guarded.
      assert [{":consistency_catch:d/1", ":ets:update_counter/3", "exception_guarded", 3, 1}] =
               rows([:consistency_catch])
    end
  end

  describe "how the deviant stands" do
    defp stands(modules) do
      {:ok, result} = Memo.run_analyses(modules, analyses: [:failure])
      {:ok, results} = Memo.analyze(modules, :failure)

      [[_, _, _, "exception_guarded", _, _, _, raises, cover, caught]] =
        results["inconsistent_handling"]

      [f] = Enum.filter(result.findings, &(&1.title =~ "update_counter" or &1.title =~ "call/2"))
      {{raises, cover, caught}, f}
    end

    test "a site no try covers, here or on some way in, is called bare" do
      skip_without_souffle()
      assert {{"exit", "none", ""}, f} = stands([C.DeviantBare])

      assert f.title ==
               "GenServer.call/2 called bare where every other call site catches its exit"

      assert f.detail =~ "calls GenServer.call/2 with no try around it"
      assert f.detail =~ "4 of the 5 call sites in this program catch its exit"
      assert f.at_label == "called outside any try"

      # A helper one caller guards and another calls bare: none here, and
      # some way in passes none.
      assert {{"error", "none", ""}, f} = stands([C.HelperOutsideTry])
      assert f.title =~ "called bare where every other call site catches its error"
    end

    test "a site in a try that takes nothing says so" do
      skip_without_souffle()
      assert {{"error", "try", ""}, f} = stands([C.HiddenDeviant])

      assert f.title ==
               ":ets.update_counter/3 called in a try that lets its error through " <>
                 "where every other call site catches it"

      assert f.detail =~
               "calls :ets.update_counter/3 inside a try that catches nothing; " <>
                 "the call raises an error, and 3 of the 4 call sites"

      assert f.at_label == "in a try that catches nothing"
      refute f.title =~ "bare"
    end

    test "a site in a try that takes another class names what it takes" do
      skip_without_souffle()
      assert {{"error", "try", "exit"}, f} = stands([C.WrongClassDeviant])
      assert f.detail =~ "inside a try that catches only :exit; the call raises an error"
      assert f.at_label == "in a try that catches only :exit"
      assert hd(f.help) == "catch the error in that try, as the other sites do"
    end

    test "a site every way into which passes a try of another class says so" do
      skip_without_souffle()
      assert {{"error", "callers", ""}, f} = stands([C.CallersWrongClass])

      assert f.title ==
               ":ets.update_counter/3 called with its error uncaught " <>
                 "where every other call site catches it"

      assert f.detail =~
               "outside any try; every way into the function passes one, " <>
                 "but not always one that catches an error"

      assert f.at_label == "outside any try; its callers' tries miss an error"
    end
  end

  describe "a guard the callers hold" do
    test "a private helper called only inside a try is guarded by it" do
      skip_without_souffle()
      assert rows([C.CallerGuards]) == []
    end

    test "a belief its callers hold is shown as theirs" do
      skip_without_souffle()
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.GuardedByCallers])
      assert func =~ "GuardedByCallers:d/1"

      {:ok, result} = Memo.run_analyses([C.GuardedByCallers], analyses: [:failure])
      assert [f] = Enum.filter(result.findings, &(&1.title =~ "called bare"))
      assert length(f.related) == 3

      assert Enum.all?(
               f.related,
               &(&1.label == "guarded by a try around every call of its function")
             )
    end

    test "a closure run inside a try, in the same process, is guarded by it" do
      skip_without_souffle()
      assert rows([C.ClosureInTry]) == []
    end

    test "a closure handed to another process is not" do
      skip_without_souffle()
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.TaskInTry])
      assert func =~ "TaskInTry:-d/1-fun-0-/1"
    end

    test "a helper with one bare way in is the deviant" do
      skip_without_souffle()
      assert [{func, _, "exception_guarded", 3, 1}] = rows([C.HelperOutsideTry])
      assert func =~ "HelperOutsideTry:bump/1"
    end
  end

  describe "the population" do
    defp targets(modules) do
      {:ok, results} = Memo.analyze(modules, :failure)

      for [func, _, _, _, agree, deviate, target | _] <- results["inconsistent_handling"],
          do: {func, agree, deviate, target}
    end

    test "is the callee's sites on the same literal target" do
      skip_without_souffle()
      assert targets([C.PerTarget]) == []

      # Four call sites on :gvar, not one helper called four times: pooled
      # with :stats they would be four against one, so the quiet result
      # above is the scoping's.
      {:ok, facts} =
        Argus.Pipeline.extract([C.PerTarget], extractors: [Argus.Extractors.ErrorHandling])

      assert Enum.count(facts[:call_result], &(List.last(&1) == ":gvar")) == 4

      assert [{func, "4", "1", ":gvar"}] = targets([C.SameTargetBare])
      assert func =~ "SameTargetBare:e/1"
    end

    test "is never the other targets' sites, however many agree" do
      skip_without_souffle()
      assert targets([C.SequinLiteral]) == []
    end

    test "is the module's processes for a client call on the pid it is handed" do
      skip_without_souffle()

      assert [{func, "4", "1", "processes of Argus.Test.Fixtures.Consistency.DeviantBare"}] =
               targets([C.DeviantBare])

      assert func =~ "DeviantBare:e/1"
    end

    test "is the target's own sites once any of them agrees" do
      skip_without_souffle()
      assert targets([C.OwnSplit]) == []
    end

    test "spans targets only for a callee that fails on a missing row" do
      skip_without_souffle()
      assert targets([C.TableMissing]) == []
    end

    test "is none when the site's target is unknown" do
      skip_without_souffle()
      assert targets([C.UnknownTargetBare]) == []
    end

    test "is what a helper returns when the helper builds the target" do
      skip_without_souffle()

      assert [{func, "3", "1", "what Argus.Test.Fixtures.Consistency.ViaClient:via/1 returns"}] =
               targets([C.ViaClient])

      assert func =~ "ViaClient:d/1"
    end

    test "draws the evidence from the deviant's own population" do
      skip_without_souffle()

      {:ok, result} =
        Memo.run_analyses([C.SameTargetBare, C.OtherTable], analyses: [:failure])

      assert [f] = Enum.filter(result.findings, &(&1.title =~ "called bare"))
      assert f.related != []
      assert Enum.all?(f.related, &(elem(&1.mfa, 0) == C.SameTargetBare))
    end
  end

  describe "macro-generated code" do
    test "a site another module's macro wrote is not the program's" do
      skip_without_souffle()
      assert rows([C.GeneratedBare]) == []
    end

    test "the same site written by hand is the deviant" do
      skip_without_souffle()
      assert [{func, _, "exception_guarded", 4, 1}] = rows([C.WrittenBare])
      assert func =~ "WrittenBare:stop/1"
    end

    test "the extractor names the macro's module" do
      {:ok, facts} =
        Argus.Pipeline.extract([C.GeneratedBare], extractors: [Argus.Extractors.Generated])

      assert [
               "Argus.Test.Fixtures.Consistency.GeneratedBare:stop/1",
               "Argus.Test.Fixtures.Consistency.StopMacro"
             ] in facts[:macro_generated]

      refute Enum.any?(facts[:macro_generated], fn [f, _] -> f =~ ":guarded" end)
    end
  end

  describe "severity" do
    defp finding(agree, deviate) do
      Failure.finding(:inconsistent_handling, [
        "M:f/1",
        "M:f/1#3",
        "DynamicSupervisor:start_child/2",
        "result_checked",
        to_string(agree),
        to_string(deviate),
        "",
        "",
        "",
        ""
      ])
    end

    test "is how unlikely the deviation is: seven to one warns, three to one informs" do
      assert finding(7, 1).severity == :warning
      assert finding(3, 1).severity == :info
    end

    test "says every other call site only when this one is the sole deviant" do
      assert finding(5, 1).title =~ "where every other call site checks it"
      assert finding(9, 3).title =~ "where most call sites check it"

      guarded =
        Failure.finding(:inconsistent_handling, [
          "M:f/1",
          "M:f/1#3",
          "GenServer:call/2",
          "exception_guarded",
          "9",
          "3",
          "",
          "exit",
          "none",
          ""
        ])

      assert guarded.title =~ "called bare where most call sites catch its exit"
      assert guarded.detail =~ "9 of the 12 call sites in this program catch its exit"
    end

    test "names the counts and the callee, and anchors the deviant site" do
      f = finding(5, 1)
      assert f.title =~ "start_child/2"
      assert f.detail =~ "5 of the 6 call sites"
      assert f.at_label =~ "disagrees"
      assert f.instr != nil
    end

    test "shows a few of the sites that follow the convention" do
      skip_without_souffle()
      {:ok, result} = Memo.run_analyses([C.DeviantIgnore], analyses: [:failure])

      assert [f] = Enum.filter(result.findings, &(&1.title =~ "result ignored"))
      labels = Enum.map(f.related, & &1.label)
      assert labels != [] and length(labels) <= 3
      assert Enum.all?(labels, &(&1 == "its result matched here"))
      assert Enum.all?(f.related, &(&1.instr != nil))
    end
  end
end
