defmodule Scry.AnalysisRulesTest do
  @moduledoc """
  What a warm graph does when the argus it runs moves without any beam
  moving: a rule edit re-solves exactly the analyses whose programs it
  touched and re-extracts nothing; an argus code change re-extracts.
  """

  use ExUnit.Case, async: false

  alias Roux.Input
  alias Scry.Test.{Graph, QueryLog}

  @moduletag :souffle
  @moduletag timeout: 300_000

  @analyses [:coupling, :mailbox]

  setup_all do
    %{paths: Graph.compile_parity!(Path.join(System.tmp_dir!(), "scry_rules_ebin"))}
  end

  setup %{paths: paths} do
    db = Graph.new_db(paths)
    log = QueryLog.start()

    # The database is linked to the test process and goes with it.
    on_exit(fn -> QueryLog.detach(log) end)

    Graph.incremental(db, @analyses)
    QueryLog.reset(log)
    %{db: db, log: log}
  end

  test "a rule edit re-solves only the analysis it touched", %{db: db, log: log} do
    :ok = Input.set(db, :rules_digest, :mailbox, "mailbox.dl edited")
    Graph.incremental(db, @analyses)

    assert QueryLog.executions(log, :souffle_solve) == [:mailbox]
    assert QueryLog.executions(log, :module_extraction) == []
    assert QueryLog.executions(log, :stage0_facts) == []
  end

  test "a stage-0 rule edit re-derives the call graph, not the facts", %{db: db, log: log} do
    :ok = Input.set(db, :rules_digest, :stage0, "stage0.dl edited")
    Graph.incremental(db, @analyses)

    assert QueryLog.executions(log, :stage0_facts) == [:all]
    assert QueryLog.executions(log, :module_extraction) == []
  end

  test "an argus code change re-extracts every module", %{db: db, log: log, paths: paths} do
    :ok = Input.set(db, :env_fingerprint, :all, %{test: 2})
    Graph.incremental(db, @analyses)

    assert length(QueryLog.executions(log, :module_extraction)) == map_size(paths)
    assert Enum.sort(QueryLog.executions(log, :souffle_solve)) == @analyses
  end

  test "without rules digests, a revision that moves nothing solves nothing", %{paths: paths} do
    # A frontend that never sets the digests (planchette's).
    db = Graph.new_db(paths, rules: false)
    Graph.incremental(db, @analyses)

    log = QueryLog.start()
    on_exit(fn -> QueryLog.detach(log) end)

    # A :high input moves, so validation walks every solve's edges
    # instead of skipping them on durability; none of them moved.
    :ok = Input.set(db, :project_root, :all, "/elsewhere")
    Graph.incremental(db, @analyses)

    assert QueryLog.executions(log, :souffle_solve) == []
  end
end
