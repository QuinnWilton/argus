defmodule Argus.Analyses.TransactionSafetyTest do
  use ExUnit.Case

  alias Argus.Purity.Effects
  alias Argus.Souffle
  alias Argus.Test.Fixtures.Transaction, as: T

  @all [
    T.FakeRepo,
    T.Unsafe,
    T.UnsafeIndirect,
    T.Sleeps,
    T.LogsOnly,
    T.ReadsConfig,
    T.EffectOutside
  ]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp findings(modules \\ @all) do
    assert {:ok, r} = Argus.analyze(modules, :transaction_safety)
    Map.get(r, "effect_in_transaction", [])
  end

  defp for_module(rows, fragment) do
    Enum.filter(rows, fn [caller, _repo, _cat, _api, _via] ->
      String.contains?(caller, fragment)
    end)
  end

  describe "detection" do
    test "an unrollbackable effect in the transaction body is reported" do
      skip_without_souffle()

      assert [[caller, repo, "network", api, via]] = for_module(findings(), "Unsafe:create/1")

      assert caller =~ "Unsafe:create/1"
      assert repo =~ "FakeRepo"
      assert api =~ "httpc.request"
      assert via =~ "-create/1-fun-0-", "should name the closure, not the enclosing function"
    end

    test "an effect several calls inside the transaction is attributed to its site" do
      skip_without_souffle()

      assert [[_caller, _repo, "network", _api, via]] =
               for_module(findings(), "UnsafeIndirect:create/1")

      assert via =~ "deliver/1", "blamed the transaction rather than the function at fault"
    end

    test "sleeping inside a transaction is reported" do
      skip_without_souffle()

      # The purest form of the connection-holding problem: a pooled
      # connection checked out and doing nothing.
      assert [[_caller, _repo, "process", api, _via]] = for_module(findings(), "Sleeps:create/1")
      assert api =~ "sleep"
    end

    test "the repo is found by behaviour, not by being called Repo" do
      skip_without_souffle()

      # FakeRepo only declares @behaviour Ecto.Repo. An app's own repo can
      # be called anything, so matching on the name would miss most of them.
      assert [[_c, repo, _cat, _api, _v] | _] = for_module(findings(), "Unsafe:create/1")
      assert repo =~ "FakeRepo"
    end
  end

  describe "what must not be reported" do
    # These three are the difference between a usable analysis and one
    # nobody runs twice.

    test "logging inside a transaction is fine" do
      skip_without_souffle()

      assert for_module(findings(), "LogsOnly") == [],
             "Logger is the most common effect inside a transaction by far"
    end

    test "reading configuration inside a transaction is fine" do
      skip_without_souffle()

      # Impure — it breaks referential transparency — but there is nothing
      # for a rollback to undo. This is why impure_call carries a mode.
      assert for_module(findings(), "ReadsConfig") == []
    end

    test "an effect after the transaction commits is the correct shape" do
      skip_without_souffle()

      assert for_module(findings(), "EffectOutside") == []
    end
  end

  describe "the read/write distinction" do
    test "reads and writes in the same module are told apart" do
      # The model dimension this analysis rests on. Without it every
      # Application.get_env/2 in a transaction is a finding, and the real
      # ones drown.
      assert {:impure, :process, :read} = Effects.classify("Application", "get_env")
      assert {:impure, :process, :write} = Effects.classify("Application", "put_env")

      assert {:impure, :io, :read} = Effects.classify("File", "read")
      assert {:impure, :io, :write} = Effects.classify("File", "write")

      assert {:impure, :ets, :read} = Effects.classify(":ets", "lookup")
      assert {:impure, :ets, :write} = Effects.classify(":ets", "insert")
    end

    test "an unlisted effect defaults to write" do
      # The safe direction: a false "irreversible" costs a look, a false
      # "harmless" costs the bug.
      assert {:impure, :network, :write} = Effects.classify(":httpc", "request")
      assert Effects.mode("SomeUnknown", "thing") == :write
    end

    test "purity still rejects reads, which reversibility does not" do
      skip_without_souffle()

      # The same call is disqualifying for one contract and harmless for
      # the other — which is the whole reason for two dimensions.
      assert for_module(findings(), "ReadsConfig") == []

      assert {:impure, :process, :read} = Effects.classify("Process", "get")
    end
  end
end
