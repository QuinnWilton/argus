defmodule Argus.Analyses.PurityTest do
  use ExUnit.Case

  alias Argus.Purity.Effects
  alias Argus.Souffle
  alias Argus.Test.Fixtures.Purity, as: P

  doctest Argus.Purity.Effects

  @all [
    P.Clean,
    P.DirectEffects,
    P.IndirectEffects,
    P.EffectfulClosure,
    P.Unprovable,
    P.Undeclared
  ]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp run(modules \\ @all) do
    assert {:ok, r} = Argus.analyze(modules, :purity)

    %{
      verified: Map.get(r, "purity_verified", []) |> Enum.map(&hd/1),
      violated: Map.get(r, "purity_violated", []),
      unprovable: Map.get(r, "purity_unprovable", [])
    }
  end

  defp names(rows) when is_list(rows), do: Enum.map(rows, &hd/1)

  defp find(by_func, fragment) do
    {_k, v} = Enum.find(by_func, fn {k, _v} -> String.contains?(k, fragment) end)
    v
  end

  describe "the contract reaches the analysis" do
    test "@pure true is persisted into the beam and read back" do
      # The declaration has to survive compilation, or the analysis is
      # checking nothing. It travels as a persisted module attribute.
      declared = Argus.Purity.declared(P.Clean)

      assert {:add, 2} in declared
      assert {:total, 1} in declared
      assert Argus.Purity.declared(P.Undeclared) == []
    end

    test "the marker does not leak to the next definition" do
      # @pure is deleted after each definition. Without that, one marker
      # would silently apply to every function below it and the contract
      # would mean nothing.
      declared = Argus.Purity.declared(P.Clean)

      refute {:sum, 2} in declared
      assert {:scale, 2} in declared
    end
  end

  describe "verified" do
    test "arithmetic, recursion through a private helper, and pure closures" do
      skip_without_souffle()

      %{verified: verified} = run()

      assert Enum.any?(verified, &(&1 =~ "Clean:add/2"))
      assert Enum.any?(verified, &(&1 =~ "Clean:bang!/1")), "raising is not an effect"

      assert Enum.any?(verified, &(&1 =~ "Clean:total/1")),
             "did not follow into an undeclared private helper"

      assert Enum.any?(verified, &(&1 =~ "Clean:scale/2")),
             "a closure that is itself pure must not make its builder impure"
    end
  end

  describe "violated" do
    test "an effect in the function itself, with the right category" do
      skip_without_souffle()

      %{violated: violated} = run()

      by_func =
        Map.new(violated, fn [func, category, api, _via] -> {func, {category, api}} end)

      assert {"io", "IO.puts/1"} = find(by_func, "DirectEffects:logs/1")
      assert {"process", ":erlang.send/2"} = find(by_func, "DirectEffects:sends/2")
      assert {"time", _} = find(by_func, "DirectEffects:reads_clock/0")
      assert {"random", ":rand.uniform/1"} = find(by_func, "DirectEffects:randomises/0")
      assert {"process", "Process.put/2"} = find(by_func, "DirectEffects:process_dict/1")
    end

    test "an effect several calls away is attributed to the function performing it" do
      skip_without_souffle()

      %{violated: violated} = run()

      assert [[func, "io", "IO.inspect/1", via]] =
               Enum.filter(violated, fn [f, _, _, _] -> f =~ "IndirectEffects:outer/1" end)

      assert func =~ "outer/1"
      assert via =~ "inner/1", "blamed the declaring function rather than the one at fault"
    end

    test "an effect inside a closure the function builds counts against it" do
      skip_without_souffle()

      # The compiler lifts the lambda to its own function; argus records a
      # closure_def edge, so the existing call graph reaches it. Worth
      # pinning because it is load-bearing and invisible.
      %{violated: violated} = run()

      assert [[_func, "io", "IO.puts/1", via]] =
               Enum.filter(violated, fn [f, _, _, _] -> f =~ "EffectfulClosure:each/1" end)

      assert via =~ "-each/1-fun-0-", "did not follow into the lifted closure"
    end
  end

  describe "unprovable" do
    test "a call through a fun value cannot be verified" do
      skip_without_souffle()

      %{unprovable: unprovable, violated: violated} = run([P.Unprovable])

      assert Enum.any?(names(unprovable), &(&1 =~ "applies/2"))
      assert violated == [], "an unfollowable call is not itself an effect"
    end

    test "apply/3 is unprovable, not impure" do
      skip_without_souffle()

      # apply observes nothing; what it reaches might, and that is exactly
      # what cannot be determined. Reporting it as an effect would be a
      # different and wrong claim.
      %{unprovable: unprovable} = run([P.Unprovable])

      assert [[_func, "dynamic_call", "apply", _via]] =
               Enum.filter(unprovable, fn [f, _, _, _] -> f =~ "dispatches/3" end)
    end

    test "a violation outranks unprovability" do
      skip_without_souffle()

      # A function that both performs a known effect and makes an
      # unfollowable call is a violation — the effect is proven, so
      # reporting only "cannot check" would bury it.
      %{violated: violated, unprovable: unprovable} = run()

      violated_funcs = names(violated) |> MapSet.new()
      unprovable_funcs = names(unprovable) |> MapSet.new()

      assert MapSet.disjoint?(violated_funcs, unprovable_funcs)
    end
  end

  describe "higher-order contracts" do
    # A declared-pure function that calls the fun it is given cannot be
    # verified in isolation — its purity is whatever the caller handed it.
    # That obligation is decidable at the CALL SITE, which is also where the
    # fix belongs.

    test "passing an effectful closure to a pure function blames the caller" do
      skip_without_souffle()

      assert {:ok, r} =
               Argus.analyze([P.HigherOrder, P.GoodCaller, P.BadCaller], :purity)

      assert [[caller, callee, closure, "io", "IO.puts/1"]] =
               Map.get(r, "impure_closure_to_pure", [])

      assert caller =~ "BadCaller:trace/1"
      assert callee =~ "HigherOrder:transform/2"
      assert closure =~ "-trace/1-fun-0-", "named the caller rather than its lambda"
    end

    test "passing a pure closure is not reported" do
      skip_without_souffle()

      assert {:ok, r} = Argus.analyze([P.HigherOrder, P.GoodCaller], :purity)
      assert Map.get(r, "impure_closure_to_pure", []) == []
    end

    test "the higher-order function is recognised through its lifted closure" do
      skip_without_souffle()

      # `Enum.map(list, fn x -> f.(x) end)` puts the call_fun inside the
      # LIFTED closure, so transform/2 never contains one itself. Matching
      # only on the declared function's own body would leave this rule dead
      # while still passing a naive test.
      {:ok, facts} =
        Argus.Pipeline.extract([P.HigherOrder], extractors: [Argus.Extractors.Purity])

      callers = for [_id, caller, _kind] <- Map.get(facts, :dynamic_call, []), do: caller

      assert Enum.all?(callers, &String.contains?(&1, "-fun-")),
             "the call_fun was in the declared function after all; this test is vacuous"
    end
  end

  describe "scope" do
    test "functions that claim nothing are never reported" do
      skip_without_souffle()

      %{verified: v, violated: vi, unprovable: u} = run()
      all = v ++ names(vi) ++ names(u)

      refute Enum.any?(all, &(&1 =~ "Undeclared")),
             "reported a module that made no purity claim"

      refute Enum.any?(all, &(&1 =~ "Clean:sum/2")),
             "reported an undeclared private helper in its own right"
    end
  end

  describe "the effect model" do
    test "classifies the three buckets" do
      assert Effects.classify("IO", "puts") == {:impure, :io}
      assert Effects.classify(":ets", "insert") == {:impure, :ets}
      assert Effects.classify(":erlang", "put") == {:impure, :process_dict}
      assert Effects.classify(":erlang", "monotonic_time") == {:impure, :time}

      assert Effects.classify("Enum", "map") == :pure
      assert Effects.classify(":lists", "reverse") == :pure
      assert Effects.classify(":erlang", "+") == :pure

      assert Effects.classify("MyApp.Repo", "all") == :unknown
      assert Effects.classify("SomeDep", "call") == :unknown
    end

    test "a function-level entry beats its module's default" do
      # :erlang is pure by default with a listed impure minority. If that
      # precedence inverted, every arithmetic BIF would become unprovable
      # and the analysis would report nothing useful.
      assert Effects.classify(":erlang", "put") == {:impure, :process_dict}
      assert Effects.classify(":erlang", "length") == :pure
    end

    test "every category used is declared in the type's domain" do
      known =
        ~w(io process process_dict ets port node time random network code_loading)a

      assert Enum.sort(Effects.categories()) == Enum.sort(known)
    end
  end
end
