defmodule Argus.DriverCrashTest do
  @moduledoc """
  An analysis whose findings raise — argus's rules and code out of step,
  or a bug — degrades like one whose solver failed, and the other
  analyses still report.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Graph
  alias Roux.Memo

  @moduletag :souffle
  @moduletag timeout: 300_000

  test "a raising analysis is degraded, not the run" do
    db = Graph.new_db(Graph.parity!())
    Graph.incremental(db, [:coupling, :mailbox])

    # A solve whose value argus cannot build findings from.
    key = {:solve, {:test, :mailbox}}
    {:ok, entry} = Memo.get(db, key)
    bogus = {:ok, :not_outputs}
    :ok = Memo.put(db, key, %{entry | value: bogus, hash: :erlang.phash2(bogus)})

    located = Argus.Graph.located(db, :test, [:coupling, :mailbox])

    assert %{mailbox: {:error, {:crashed, banner}}, coupling: {:ok, coupling}} = located
    assert is_binary(banner)
    assert Enum.any?(coupling, &(&1.finding.analysis == :coupling))
  end
end
