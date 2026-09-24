defmodule Scry.AnalysisParityTest do
  @moduledoc """
  The honesty gate: every analysis's incremental solve over the roux
  graph equals the batch run over the same beams — cold, and after each
  edit in a sequence of removals and re-additions carried by ONE
  database, so memos that outlive an edit are checked against a fresh
  batch run of the program as it now stands.

  The edits are cross-module on purpose: each removed module is the
  other end of a relation some analysis joins across modules (a
  points-to cycle, a hub its listeners register with, a Mnesia helper
  the check-then-act rules read through, the audit log a message is sent to,
  a PADL race's registrar).
  """

  # In its own peer (`Scry.Test.Peer`), whose scratch root is its own:
  # every analysis, a dozen times over, mints more fact directories than
  # the root keeps, and a prune here must not take one a solve elsewhere
  # is reading.
  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Graph, Peer}

  # A dozen batch runs of every analysis: out of the default run, in CI
  # and before any change to the shared layer (`mix test --include parity`).
  @moduletag :souffle
  @moduletag :parity
  @moduletag timeout: 600_000

  @edits [
    Argus.Test.Fixtures.PidFlow.CycleB,
    Argus.Test.Fixtures.PidFlow.Hub,
    Argus.Test.Fixtures.CheckThenAct.MnesiaHelpers,
    Argus.Test.Fixtures.UnreceivedMessage.Audit,
    Argus.Test.Fixtures.UnreceivedMessage.Helper,
    :padl2010_proc_reg
  ]

  setup_all do
    {:ok, analyses} = Argus.Analysis.set(:all)
    %{paths: Graph.parity!(), analyses: analyses, peer: Peer.start!()}
  end

  defp assert_parity(db, paths, analyses, label, batch \\ nil) do
    # The batch oracle runs beside the incremental solves: independent
    # work over the same beams.
    oracle = if batch, do: nil, else: Task.async(fn -> Graph.batch(paths, analyses) end)
    incremental = Graph.incremental(db, analyses)
    batch = batch || Task.await(oracle, :infinity)

    for analysis <- analyses do
      assert {:ok, _rows} = incremental[analysis], "#{label}: #{analysis} degraded"

      assert incremental[analysis] == batch[analysis],
             "#{label}: #{analysis} incremental ≠ batch"
    end

    incremental
  end

  defp row_count({:ok, outputs}), do: outputs |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  test "incremental equals batch, cold and across cross-module edits", %{
    paths: paths,
    analyses: analyses,
    peer: peer
  } do
    Peer.run(peer, fn -> parity(Graph.use_parity!(paths), analyses) end)
  end

  defp parity(paths, analyses) do
    for module <- @edits do
      assert Map.has_key?(paths, module), "the fixture no longer defines #{inspect(module)}"
    end

    db = Graph.new_db(paths)

    try do
      cold = assert_parity(db, paths, analyses, "cold")

      # A gate over empty outputs proves nothing: every analysis has rows.
      for analysis <- analyses do
        assert row_count(cold[analysis]) > 0, "#{analysis} solved to no rows at all"
      end

      Enum.reduce(@edits, cold, fn module, before ->
        without = Map.delete(paths, module)
        Graph.sync!(db, without)
        removed = assert_parity(db, without, analyses, "without #{inspect(module)}")

        # The removal reached at least one analysis's rows, or it tested
        # nothing incremental.
        assert removed != before, "removing #{inspect(module)} moved no analysis"

        # The program is the cold one again, so the cold batch run is its
        # oracle — and the incremental outputs must come back exactly.
        Graph.sync!(db, paths)
        readded = assert_parity(db, paths, analyses, "with #{inspect(module)} back", cold)
        assert readded == cold
        readded
      end)
    after
      Roux.Database.shutdown(db)
    end
  end
end
