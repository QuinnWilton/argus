defmodule Argus.Analyses.EffectsPurityTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.Purity, as: P
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @all [
    P.Clean,
    P.DirectEffects,
    P.IndirectEffects,
    P.EffectfulClosure,
    P.Unprovable,
    P.Undeclared
  ]

  defp run(modules \\ @all) do
    assert {:ok, r} = Memo.analyze(modules, :effects)

    %{
      verified: Map.get(r, "purity_verified", []) |> Enum.map(&hd/1),
      violated:
        Rows.where(r, :effects, "effect_in_context",
          context: "pure_contract",
          drop: [:context, :scope, :site, :opened]
        )
        |> Enum.uniq(),
      unprovable: Rows.where(r, :effects, "purity_unprovable", drop: [:site]) |> Enum.uniq()
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
    @describetag :flowlog

    test "arithmetic, recursion through a private helper, and pure closures" do
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
    @describetag :flowlog

    test "an effect in the function itself, with the right category" do
      %{violated: violated} = run()

      by_func =
        Map.new(violated, fn [func, category, api, _via] -> {func, {category, api}} end)

      assert {"io", "IO.puts/1"} = find(by_func, "DirectEffects:logs/1")
      assert {"process", ":erlang.send/2"} = find(by_func, "DirectEffects:sends/2")
      assert {"time", _} = find(by_func, "DirectEffects:reads_clock/0")
      assert {"random", ":rand.uniform/1"} = find(by_func, "DirectEffects:randomises/0")
      assert {"process_dict", "Process.put/2"} = find(by_func, "DirectEffects:process_dict/1")
    end

    test "an effect that compiles to a bif instruction is read, and a guard bif is not one" do
      %{violated: violated, verified: verified} = run([P.BifEffects])

      by_func =
        Map.new(violated, fn [func, category, api, _via] -> {func, {category, api}} end)

      assert {"process", ":erlang.self/0"} = find(by_func, "BifEffects:me/0")
      assert {"node", ":erlang.node/0"} = find(by_func, "BifEffects:here/0")
      assert {"process_dict", ":erlang.get/1"} = find(by_func, "BifEffects:cached/1")

      assert Enum.any?(verified, &(&1 =~ "BifEffects:owner_node/1")), "node/1 reads its argument"
      assert Enum.any?(verified, &(&1 =~ "BifEffects:head_size/2"))
    end

    test "an effect several calls away is attributed to the function performing it" do
      %{violated: violated} = run()

      assert [[func, "io", "IO.inspect/1", via]] =
               Enum.filter(violated, fn [f, _, _, _] -> f =~ "IndirectEffects:outer/1" end)

      assert func =~ "outer/1"
      assert via =~ "inner/1", "blamed the declaring function rather than the one at fault"
    end

    test "an effect inside a closure the function builds counts against it" do
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
    @describetag :flowlog

    test "a call through a fun value cannot be verified" do
      %{unprovable: unprovable, violated: violated} = run([P.Unprovable])

      assert Enum.any?(names(unprovable), &(&1 =~ "applies/2"))
      assert violated == [], "an unfollowable call is not itself an effect"
    end

    test "apply/3 is unprovable, not impure" do
      # apply observes nothing; what it reaches might, and that is exactly
      # what cannot be determined. Reporting it as an effect would be a
      # different and wrong claim.
      %{unprovable: unprovable} = run([P.Unprovable])

      assert [[_func, "dynamic_call", "apply", _via]] =
               Enum.filter(unprovable, fn [f, _, _, _] -> f =~ "dispatches/3" end)
    end

    test "apply with a literal MFA is resolved, not given up on" do
      # `apply` is only opaque when M and F are genuinely unknown. With
      # literals it is a static call wearing a disguise, and giving up on it
      # would be laziness rather than honesty.
      %{verified: verified, unprovable: unprovable} = run([P.ResolvedApply])

      assert Enum.any?(verified, &(&1 =~ "reverse/1")),
             "apply(Enum, :reverse, [list]) is a call to a pure function"

      assert unprovable == []
    end

    test "apply to an impure literal target is a violation, naming the target" do
      # The payoff of resolving: seeing THROUGH the apply turns what would
      # have been a shrug into a proven violation that names IO.puts/1.
      %{violated: violated} = run([P.ResolvedApply])

      assert [[func, "io", "IO.puts/1", _via]] =
               Enum.filter(violated, fn [f, _, _, _] -> f =~ "shout/1" end)

      assert func =~ "ResolvedApply:shout/1"
    end

    test "a violation outranks unprovability" do
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
    @describetag :flowlog

    # A declared-pure function that calls the fun it is given cannot be
    # verified in isolation — its purity is whatever the caller handed it.
    # That obligation is decidable at the CALL SITE, which is also where the
    # fix belongs.

    test "passing an effectful closure to a pure function blames the caller" do
      assert {:ok, r} =
               Memo.analyze([P.HigherOrder, P.GoodCaller, P.BadCaller], :effects)

      # The one row is BadCaller's: GoodCaller hands transform/2 a pure
      # closure, which is not reported.
      assert [[caller, callee, closure, "io", "IO.puts/1"]] =
               Rows.where(r, :effects, "impure_closure_to_pure", drop: [:site, :effect_site])

      assert caller =~ "BadCaller:trace/1"
      assert callee =~ "HigherOrder:transform/2"
      assert closure =~ "-trace/1-fun-0-", "named the caller rather than its lambda"
    end

    test "the finding anchors at the call handing the closure over, the effect as a frame" do
      assert {:ok, %{findings: findings}} =
               Memo.run_analyses([P.HigherOrder, P.BadCaller], analyses: [:effects])

      assert [finding] = Enum.filter(findings, &(&1.module == P.BadCaller))
      assert %Argus.InstrId{func: "trace", arity: 1} = finding.instr
      assert finding.at_label =~ "hands the effectful closure to transform/2"

      assert [%{label: "the closure calls IO.puts/1 here", instr: %Argus.InstrId{func: f}}] =
               finding.related

      assert f =~ "-trace/1-fun-0-"
    end

    test "a violated contract points at the effect it performs" do
      assert {:ok, %{findings: findings}} =
               Memo.run_analyses([P.DirectEffects], analyses: [:effects])

      logs = Enum.find(findings, &(&1.mfa == {P.DirectEffects, :logs, 1}))
      assert logs.at_label == "declared pure here"
      assert [%{label: "I/O here", instr: %Argus.InstrId{func: "logs", arity: 1}}] = logs.related
    end

    test "the higher-order function is recognised through its lifted closure" do
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
    @describetag :flowlog

    test "functions that claim nothing are never reported" do
      %{verified: v, violated: vi, unprovable: u} = run()
      all = v ++ names(vi) ++ names(u)

      refute Enum.any?(all, &(&1 =~ "Undeclared")),
             "reported a module that made no purity claim"

      refute Enum.any?(all, &(&1 =~ "Clean:sum/2")),
             "reported an undeclared private helper in its own right"
    end
  end
end
