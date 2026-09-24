defmodule Argus.Analyses.BlockingSelfCallTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.PidCalls
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  setup do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  test "a call to self(), to the module's own name or through a helper is a self-call" do
    {:ok, r} = Memo.analyze([PidCalls.SelfCaller], :blocking)

    funcs =
      r
      |> Rows.where(:blocking, "call_cycle", phase: "self")
      |> Enum.map(fn [mod, mod, func, func, "self", site, site] -> {func, site} end)

    # handle_call/3's three self-calls — self(), the name, and self()
    # handed to ping/1 — and not the cast to itself.
    assert length(funcs) == 3
    assert Enum.all?(funcs, fn {func, _} -> func =~ "SelfCaller:handle_call/3" end)
    assert funcs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 3
  end

  test "the finding anchors at the call and names :calling_self" do
    {:ok, %{findings: findings}} =
      Memo.run_analyses([PidCalls.SelfCaller], analyses: [:blocking])

    self_calls =
      Enum.filter(findings, &(&1.title == "Synchronous call to the calling process itself"))

    assert length(self_calls) == 3
    assert Enum.all?(self_calls, &(&1.severity == :error and &1.detail =~ ":calling_self"))
    assert Enum.all?(self_calls, &match?(%Argus.InstrId{func: "handle_call"}, &1.instr))
  end
end
