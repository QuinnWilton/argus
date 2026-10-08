defmodule Argus.Analyses.BlockingSelfCallTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.PidCalls
  alias Argus.Test.Memo

  test "a call to self(), to the module's own name or through a helper is a self-call" do
    {:ok, %{findings: findings}} =
      Memo.run_analyses([PidCalls.SelfCaller], analyses: [:blocking])

    self_calls =
      Enum.filter(findings, &(&1.title == "Synchronous call to the calling process itself"))

    # handle_call/3's three self-calls (self(), the name, and self()
    # handed to ping/1) and not the cast to itself, each anchored at its
    # call and naming :calling_self.
    assert length(self_calls) == 3
    assert self_calls |> Enum.map(& &1.instr) |> Enum.uniq() |> length() == 3
    assert Enum.all?(self_calls, &match?(%Argus.InstrId{func: "handle_call"}, &1.instr))
    assert Enum.all?(self_calls, &(&1.severity == :error and &1.detail =~ ":calling_self"))
  end
end
