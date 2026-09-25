defmodule Scry.AnalysisRulesTest do
  @moduledoc """
  What a warm graph does when the argus it runs moves without any beam
  moving: a rule edit re-solves exactly the analyses whose programs it
  touched and re-extracts nothing; an edit to the code argus's producers
  run re-extracts every module, and solves only where the rows moved;
  a schema entry that moved re-extracts the modules that read it; any
  other argus edit rebuilds the findings and extracts nothing; a
  runtime change re-extracts and re-solves everything.

  The query log's telemetry handlers are VM-wide, so the graphs run in
  this module's peer (`Scry.Test.Peer`).
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Roux.{Input, Memo}
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
      db = Graph.new_db(paths, Keyword.take(opts, [:rules, :argus]))
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

  defp findings!(db) do
    for analysis <- @analyses, do: {:ok, _} = Scry.Analysis.findings(db, analysis)
    :ok
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

  test "an edit to the bounded points-to program re-derives the stage, as one to the exact one",
       context do
    # The stage runs the bounded program in the exact one's place when
    # the exact fixpoint outgrows its budget: keyed on the exact program
    # alone, an edit to the bounded one served what it no longer stages.
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :rules_digest, :points_to_bounded, "points_to_bounded.dl edited")
      Graph.incremental(db, @analyses)

      assert QueryLog.executions(log, :points_to_facts) == [:all]
      assert QueryLog.executions(log, :stage0_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []
      assert QueryLog.executions(log, :module_extraction) == []
    end)
  end

  test "an edit to argus's producers re-extracts every module, and solves nothing it left",
       %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      findings!(db)
      :ok = Input.set(db, :extraction_code, :all, "an extractor edited")
      QueryLog.reset(log)

      Graph.incremental(db, @analyses)
      findings!(db)

      assert length(QueryLog.executions(log, :module_extraction)) == map_size(paths)

      # The same rows: every module's facts, and every solve reading
      # them, validate without executing. The relations' text is argus's
      # encoding, which that code writes: digested again, and equal.
      assert QueryLog.executions(log, :module_semantic_facts) == []
      assert QueryLog.executions(log, :relation_digest) != []
      assert QueryLog.executions(log, :stage0_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      # Nothing else of argus's moved: the findings stand.
      assert QueryLog.executions(log, :findings) == []
    end)
  end

  test "an argus edit outside its producers rebuilds the findings, and extracts nothing",
       context do
    # A finding's prose, or a relation added to the schema: no entry of
    # the schema read so far moved (and no program loads the new
    # relation, so no rules digest moves: `Scry.FingerprintTest`).
    in_graph(context, [warm: true], fn db, log ->
      findings!(db)
      :ok = Input.set(db, :argus_code, :all, "a finding's prose edited")
      QueryLog.reset(log)

      Graph.incremental(db, @analyses)
      findings!(db)

      assert Enum.sort(QueryLog.executions(log, :findings)) == @analyses
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :relation_digest) == []
      assert QueryLog.executions(log, :analysis_input_relations) == []
      assert QueryLog.executions(log, :stage0_facts) == []
      assert QueryLog.executions(log, :points_to_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      # Each schema entry read so far was digested again, and came out
      # the same.
      assert [_ | _] = digested = QueryLog.executions(log, :schema_read)
      assert QueryLog.cutoffs(log, :schema_read) == digested
    end)
  end

  test "a schema entry that moved re-extracts the modules that read it, and re-solves its loaders",
       %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      findings!(db)
      read = {:schema_read, "columns supervisor"}

      readers =
        for module <- Map.keys(paths),
            {:ok, dependencies} = Memo.dependencies(db, {:module_extraction, module}),
            read in dependencies,
            do: module

      # Some of the modules, not all: the ones whose rows it holds.
      assert readers != []
      assert length(readers) < map_size(paths)

      # As if `supervisor` had other columns when these memos were made:
      # its entry's digest then, argus's code then, and the rules digest
      # of the one program here that loads it, whose declaration moved.
      {:ok, entry} = Memo.get(db, read)
      :ok = Memo.put(db, read, %{entry | value: "before", hash: :erlang.phash2("before")})
      :ok = Input.set(db, :argus_code, :all, "supervisor's columns edited")
      :ok = Input.set(db, :rules_digest, :coupling, "supervisor's declaration edited")
      QueryLog.reset(log)

      Graph.incremental(db, @analyses)
      findings!(db)

      assert QueryLog.executions(log, :module_extraction) == Enum.sort(readers)

      # The same rows: nothing above them runs, and only the program
      # that loads the relation solves again.
      assert QueryLog.executions(log, :module_semantic_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == [:coupling]
    end)
  end

  test "a runtime change re-extracts every module and re-solves every analysis",
       %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :env_fingerprint, :all, %{test: 2})
      Graph.incremental(db, @analyses)

      assert length(QueryLog.executions(log, :module_extraction)) == map_size(paths)
      assert Enum.sort(QueryLog.executions(log, :souffle_solve)) == @analyses
    end)
  end

  test "without argus's digests, a revision that moves nothing extracts nothing", context do
    # A frontend that never sets them (planchette's).
    in_graph(context, [argus: false, warm: true], fn db, log ->
      findings!(db)
      # A :high input moves, so validation walks every edge instead of
      # skipping it on durability; none of them moved.
      :ok = Input.set(db, :project_root, :all, "/elsewhere")
      QueryLog.reset(log)

      Graph.incremental(db, @analyses)
      findings!(db)

      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :relation_digest) == []
      assert QueryLog.executions(log, :findings) == []
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
