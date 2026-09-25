defmodule Scry.AnalysisRulesTest do
  @moduledoc """
  What a warm graph does when the argus it runs moves without any beam
  moving: a rule edit re-solves exactly the analyses whose programs it
  touched and re-extracts nothing; an argus code change re-extracts.

  The query log's telemetry handlers are VM-wide, so the graphs run in
  this module's peer (`Scry.Test.Peer`).
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Roux.Input
  alias Scry.Test.{Graph, Peer, QueryLog}

  @moduletag :souffle
  @moduletag timeout: 300_000

  @analyses [:coupling, :mailbox]

  setup_all do
    %{paths: Graph.parity!(), peer: Peer.start!()}
  end

  # Runs `fun` in the peer over a graph of the parity fixture with a query
  # log attached; `fun` takes both. A warm graph is solved cold first and
  # the log reset after, so it sees only what `fun` makes happen.
  defp in_graph(%{peer: peer, paths: paths}, opts, fun) do
    Peer.run(peer, fn ->
      Graph.use_parity!(paths)
      db = Graph.new_db(paths, Keyword.take(opts, [:rules]))
      log = QueryLog.start()

      try do
        if opts[:warm], do: Graph.incremental(db, @analyses)
        QueryLog.reset(log)
        fun.(db, log)
      after
        QueryLog.detach(log)
        Roux.Database.shutdown(db)
      end
    end)
  end

  test "a rule edit re-solves only the analysis it touched", context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :rules_digest, :mailbox, "mailbox.dl edited")
      Graph.incremental(db, @analyses)

      assert QueryLog.executions(log, :souffle_solve) == [:mailbox]
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :stage0_facts) == []
    end)
  end

  test "a stage-0 rule edit re-derives the call graph, not the facts", context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :rules_digest, :stage0, "stage0.dl edited")
      Graph.incremental(db, @analyses)

      assert QueryLog.executions(log, :stage0_facts) == [:all]
      assert QueryLog.executions(log, :module_extraction) == []
    end)
  end

  test "a points-to rule edit re-derives the stage, not the call graph", context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :rules_digest, :points_to, "points_to.dl edited")
      Graph.incremental(db, @analyses)

      assert QueryLog.executions(log, :points_to_facts) == [:all]
      assert QueryLog.executions(log, :stage0_facts) == []
      # The same rows staged again: nothing reading them re-solves.
      assert QueryLog.executions(log, :souffle_solve) == []
      assert QueryLog.executions(log, :module_extraction) == []
    end)
  end

  test "an argus code change re-extracts every module", %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :env_fingerprint, :all, %{test: 2})
      Graph.incremental(db, @analyses)

      assert length(QueryLog.executions(log, :module_extraction)) == map_size(paths)
      assert Enum.sort(QueryLog.executions(log, :souffle_solve)) == @analyses
    end)
  end

  test "without rules digests, a revision that moves nothing solves nothing", context do
    # A frontend that never sets the digests (planchette's).
    in_graph(context, [rules: false, warm: true], fn db, log ->
      # A :high input moves, so validation walks every solve's edges
      # instead of skipping them on durability; none of them moved.
      :ok = Input.set(db, :project_root, :all, "/elsewhere")
      Graph.incremental(db, @analyses)

      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end
end
