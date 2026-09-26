defmodule Argus.Extractor.ShutdownReasonTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ShutdownReason
  alias Argus.Test.Fixtures.SiblingGuard, as: G
  alias Argus.Test.Soundness.Shutdown.Reason, as: R

  defp facts(mod) do
    {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [ShutdownReason])
    facts
  end

  # {callee module, callee function} of each call `func` holds in `pos`
  # that `relation` names; the site's own remote_call or local_call row
  # names the callee.
  defp callees(facts, relation, func, pos) do
    called =
      Map.new(
        for([id, _caller, m, f, _a] <- Map.get(facts, :remote_call, []), do: {id, {m, f}}) ++
          for([id, _caller, target, _a] <- Map.get(facts, :local_call, []), do: {id, target})
      )

    for [id, ^func, ^pos | _] <- Map.get(facts, relation, []),
        Map.has_key?(called, id),
        do: Map.fetch!(called, id)
  end

  defp chooses?(facts, func, pos), do: [func, pos] in Map.get(facts, :shutdown_chooses, [])

  test "a terminate/2 whose clause for :shutdown comes first runs only that clause's calls" do
    facts = facts(G.ShutdownClauseFirst)
    terminate = "Argus.Test.Fixtures.SiblingGuard.ShutdownClauseFirst:terminate/2"

    assert chooses?(facts, terminate, "0")
    runs = callees(facts, :shutdown_runs, terminate, "0")
    assert {"File", "close"} in runs
    refute {"Argus.Test.Fixtures.SiblingGuard.Directory", "unregister"} in runs
  end

  test "a terminate/2 that only sets :normal apart runs the catch-all's calls" do
    facts = facts(G.OtherReasonFirst)
    terminate = "Argus.Test.Fixtures.SiblingGuard.OtherReasonFirst:terminate/2"

    assert chooses?(facts, terminate, "0")
    runs = callees(facts, :shutdown_runs, terminate, "0")
    assert {"Argus.Test.Fixtures.SiblingGuard.Directory", "unregister"} in runs
    # Both File.close calls: the :normal clause's is not among them.
    assert Enum.count(runs, &(&1 == {"File", "close"})) == 1
  end

  test "a guard against :shutdown leaves out the clause it guards" do
    facts = facts(R.NotShutdown)
    terminate = "Argus.Test.Soundness.Shutdown.Reason.NotShutdown:terminate/2"

    assert chooses?(facts, terminate, "0")
    assert callees(facts, :shutdown_runs, terminate, "0") == []
  end

  test "a function that never tests the parameter chooses nothing by it, and hands it on" do
    facts = facts(R.Relay)
    relay = "Argus.Test.Soundness.Shutdown.Reason.Relay:relay/2"
    leave = "Argus.Test.Soundness.Shutdown.Reason.Relay:leave/1"

    refute chooses?(facts, relay, "0")

    assert [[_id, ^relay, "0", "0"]] =
             Enum.filter(facts.shutdown_handed, &(Enum.at(&1, 1) == relay))

    # leave/1 chooses by its parameter: the :normal clause's call is not run.
    assert chooses?(facts, leave, "0")
    assert callees(facts, :shutdown_runs, leave, "0") == []
  end

  test "a value handed on some paths only is not handed" do
    facts = facts(R.HelperOtherValue)
    terminate = "Argus.Test.Soundness.Shutdown.Reason.HelperOtherValue:terminate/2"

    handed = for [id, ^terminate, "0", arg] <- facts.shutdown_handed, do: {id, arg}
    # leave(reason) hands it on; leave(:normal) does not.
    assert [{_id, "0"}] = handed
  end
end
