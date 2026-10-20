defmodule Argus.Analyses.ElementSinkTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Test.Fixtures.ElementSink, as: E
  alias Argus.Test.Memo

  defp findings(modules) do
    assert {:ok, r} = Memo.analyze(modules, :unsafe_input)

    for f <- Argus.Findings.build(Argus.Analyses.UnsafeInput, r),
        do: {f.mfa, f.title}
  end

  test "a sink handed to Enum.map as a capture runs on each element of the caller's data" do
    assert {{E.Permissions, :decode, 1},
            "Dynamic atom creation reachable from an exported function"} in findings([
             E.Permissions
           ])
  end

  test "an Erlang map takes the list second" do
    assert [{{E.Terms, :decode_all, 1}, title}] = findings([E.Terms])
    assert title =~ "binary_to_term"
  end

  test "a capture past a joiner is the third argument" do
    assert [{{E.Joined, :keys, 1}, _}] = findings([E.Joined])
  end

  test "a literal collection, or a capture of no sink, is not reported" do
    assert findings([E.Literal, E.NotASink]) == []
  end
end
