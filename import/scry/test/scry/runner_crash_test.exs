defmodule Scry.RunnerCrashTest do
  @moduledoc """
  An analysis whose findings raise — argus's rules and code out of step,
  or a bug — degrades like one whose solver failed, and the other
  analyses still report.
  """

  use ExUnit.Case, async: true

  alias Roux.Memo
  alias Scry.Test.Graph

  @moduletag :souffle
  @moduletag timeout: 300_000

  test "a raising analysis is degraded, not the run" do
    paths = Graph.parity!()
    db = Graph.new_db(paths)
    Graph.incremental(db, [:coupling, :mailbox])

    # A solve whose value argus cannot build findings from.
    key = {:souffle_solve, :mailbox}
    {:ok, entry} = Memo.get(db, key)
    bogus = {:ok, :not_outputs}
    :ok = Memo.put(db, key, %{entry | value: bogus, hash: :erlang.phash2(bogus)})

    {findings, degraded} = Scry.Runner.demand(db, [:coupling, :mailbox])

    assert [%{analysis: :mailbox, reason: {:crashed, banner}}] = degraded
    assert is_binary(banner)
    assert findings |> Map.values() |> List.flatten() |> Enum.any?(&(&1.code == "coupling"))
  end
end
