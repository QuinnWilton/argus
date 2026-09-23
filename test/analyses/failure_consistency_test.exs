defmodule Argus.Analyses.FailureConsistencyTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Failure
  alias Argus.Souffle
  alias Argus.Test.Fixtures.Consistency, as: C

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp rows(modules) do
    {:ok, results} = Argus.analyze(modules, :failure)

    for [func, _site, callee, belief, agree, deviate] <- results["inconsistent_handling"],
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
  end

  describe "severity" do
    defp finding(agree, deviate) do
      Failure.finding(:inconsistent_handling, [
        "M:f/1",
        "M:f/1#3",
        "DynamicSupervisor:start_child/2",
        "result_checked",
        to_string(agree),
        to_string(deviate)
      ])
    end

    test "is how unlikely the deviation is: seven to one warns, three to one informs" do
      assert finding(7, 1).severity == :warning
      assert finding(3, 1).severity == :info
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
      {:ok, result} = Argus.run_analyses([C.DeviantIgnore], analyses: [:failure])

      assert [f] = Enum.filter(result.findings, &(&1.title =~ "result ignored"))
      labels = Enum.map(f.related, & &1.label)
      assert labels != [] and length(labels) <= 3
      assert Enum.all?(labels, &(&1 == "its result matched here"))
      assert Enum.all?(f.related, &(&1.instr != nil))
    end
  end
end
