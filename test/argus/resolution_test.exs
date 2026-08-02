defmodule Argus.ResolutionTest do
  use ExUnit.Case, async: true

  alias Argus.Resolution

  test "reports the relations that lost targets, worst first" do
    facts = %{
      sync_call: [["a", "dynamic"], ["b", "dynamic"], ["c", "Mod"]],
      async_cast: [["a", "Mod"], ["b", "dynamic"]],
      function_def: [["f", "M", "go", "1", "true"]]
    }

    assert [{:sync_call, s}, {:async_cast, a}] = Resolution.stats(facts)

    assert s.total == 3 and s.dynamic == 2
    assert_in_delta s.resolved_pct, 33.3, 0.1
    assert a.dynamic == 1
  end

  test "relations with nothing to resolve are omitted" do
    # Reporting 100% for relations that never had a target would bury the
    # ones that did, which is the only thing this is for.
    assert Resolution.stats(%{function_def: [["f", "M", "go", "1", "true"]]}) == []
  end

  test "summary renders one line per relation that lost something" do
    facts = %{sync_call: [["a", "dynamic"], ["b", "Mod"]]}
    assert ["sync_call: 1/2 resolved (50.0%)"] = Resolution.summary(facts)
  end
end
