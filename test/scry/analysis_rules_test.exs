defmodule Scry.AnalysisRulesTest do
  @moduledoc """
  What a warm graph does when the argus it runs moves without any beam
  moving: a rule edit re-solves exactly the analyses whose programs it
  touched and re-extracts nothing; an edit to an argus producer
  re-extracts that producer alone, and solves only where its rows moved;
  any argus edit rebuilds the findings; a runtime change re-extracts
  everything.

  The query log's telemetry handlers are VM-wide, so the graphs run in
  this module's peer (`Scry.Test.Peer`).
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Argus.Extractors.GenStatem
  alias Roux.Input
  alias Scry.Test.{EditedExtractor, Graph, Peer, QueryLog}

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
      db = Graph.new_db(paths, Keyword.take(opts, [:rules, :producers, :producer_list]))
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
      assert QueryLog.extracted(log) == []
      assert QueryLog.executions(log, :stage0_facts) == []
    end)
  end

  test "a stage-0 rule edit re-derives the call graph, not the facts", context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :rules_digest, :stage0, "stage0.dl edited")
      Graph.incremental(db, @analyses)

      assert QueryLog.executions(log, :stage0_facts) == [:all]
      assert QueryLog.extracted(log) == []
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
      assert QueryLog.extracted(log) == []
    end)
  end

  # What the runner does for a producer whose digest moved: extracts it,
  # alone, for every module, ahead of the graph.
  defp prewarm!(db, paths, producers) do
    paths
    |> Map.new(fn {module, path} -> {module, {path, producers}} end)
    |> Scry.Analysis.prewarm_extractions(db)
  end

  defp moved_digest(db, producer) do
    {:ok, digest} = Input.fetch(db, :producer_digest, producer)
    %{digest | code: "edited " <> digest.code}
  end

  test "an extractor edit that leaves its rows re-extracts that producer alone",
       %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      :ok =
        Input.set(
          db,
          :producer_digest,
          Argus.Extractors.ETS,
          moved_digest(db, Argus.Extractors.ETS)
        )

      prewarm!(db, paths, [Argus.Extractors.ETS])
      Graph.incremental(db, @analyses)

      assert Enum.sort(QueryLog.executions(log, :producer_extraction)) ==
               for(
                 module <- paths |> Map.keys() |> Enum.sort(),
                 do: {module, Argus.Extractors.ETS}
               )

      # Each found its rows waiting: none extracted its module's other
      # producers on the way.
      assert Scry.Analysis.drop_prewarmed() == []

      # The same rows: every module's facts, and everything above them,
      # validate without executing.
      assert QueryLog.executions(log, :module_semantic_facts) == []
      assert QueryLog.executions(log, :stage0_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end

  test "unprewarmed, an extractor edit extracts that producer alone, beside the base",
       %{paths: paths} = context do
    # A frontend that moves a digest without the runner's pre-pass: each
    # producer that executes finds nothing waiting, and extracts itself
    # alone rather than every producer of its module.
    in_graph(context, [warm: true], fn db, log ->
      :ok =
        Input.set(
          db,
          :producer_digest,
          Argus.Extractors.ETS,
          moved_digest(db, Argus.Extractors.ETS)
        )

      Graph.incremental(db, @analyses)

      assert length(QueryLog.executions(log, :producer_extraction)) == map_size(paths)
      assert Scry.Analysis.drop_prewarmed() == []
      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end

  test "an extractor edit that moves rows re-solves only the analyses that read them",
       %{paths: paths} = context do
    producers =
      Enum.map(Scry.Analysis.producers(), fn
        GenStatem -> EditedExtractor
        producer -> producer
      end)

    in_graph(context, [warm: true, producer_list: producers], fn db, log ->
      # The modules that define a state machine: the rows the edit drops.
      statem =
        for {module, _path} <- paths,
            {:ok, facts} = Scry.Analysis.producer_extraction(db, {module, EditedExtractor}),
            Enum.any?(facts, fn {relation, rows} ->
              EditedExtractor.statem?(relation) and rows != []
            end),
            do: module

      assert statem != [], "the parity fixture defines no state machine to edit away"

      EditedExtractor.edit!()

      try do
        :ok = Input.set(db, :producer_digest, EditedExtractor, moved_digest(db, EditedExtractor))
        QueryLog.reset(log)
        prewarm!(db, paths, [EditedExtractor])
        Graph.incremental(db, @analyses)

        assert Enum.all?(
                 QueryLog.executions(log, :producer_extraction),
                 &match?({_, EditedExtractor}, &1)
               )

        assert Scry.Analysis.drop_prewarmed() == []

        assert QueryLog.executions(log, :module_semantic_facts) == Enum.sort(statem)

        # Only `:mailbox` reads a state machine's relations.
        assert QueryLog.executions(log, :souffle_solve) == [:mailbox]
      after
        EditedExtractor.revert!()
      end
    end)
  end

  test "argus's code moving rebuilds the findings, and extracts and solves nothing", context do
    in_graph(context, [warm: true], fn db, log ->
      for analysis <- @analyses, do: {:ok, _} = Scry.Analysis.findings(db, analysis)
      :ok = Input.set(db, :argus_code, :all, "argus edited")
      QueryLog.reset(log)

      for analysis <- @analyses, do: {:ok, _} = Scry.Analysis.findings(db, analysis)

      assert Enum.sort(QueryLog.executions(log, :findings)) == @analyses
      assert QueryLog.executions(log, :producer_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end

  test "the base's code moving re-encodes the relations, and solves only where they moved",
       %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :producer_digest, :base, moved_digest(db, :base))
      prewarm!(db, paths, [:base])
      Graph.incremental(db, @analyses)

      assert length(QueryLog.executions(log, :producer_extraction)) == map_size(paths)
      assert Scry.Analysis.drop_prewarmed() == []
      assert QueryLog.executions(log, :relation_digest) != []
      assert QueryLog.executions(log, :module_semantic_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end

  test "a runtime change re-extracts every producer and re-solves every analysis",
       %{paths: paths} = context do
    in_graph(context, [warm: true], fn db, log ->
      :ok = Input.set(db, :env_fingerprint, :all, %{test: 2})
      Graph.incremental(db, @analyses)

      assert length(QueryLog.executions(log, :producer_extraction)) ==
               map_size(paths) * length(Scry.Analysis.producers())

      assert Enum.sort(QueryLog.executions(log, :souffle_solve)) == @analyses
    end)
  end

  test "without producer digests, extraction joins every producer the same",
       %{paths: paths} = context do
    # A frontend that sets none of argus's inputs (planchette's), over
    # the same beams: the modules' facts are the ones a graph with them
    # has.
    modules = paths |> Map.keys() |> Enum.sort() |> Enum.take_every(7)

    materialized = fn opts ->
      in_graph(context, opts, fn db, _log ->
        symbols = Scry.Symbols.for_db(db)

        for module <- modules, into: %{} do
          {:ok, facts} = Scry.Analysis.module_extraction(db, module)
          {module, Argus.Facts.materialize(facts, symbols)}
        end
      end)
    end

    assert materialized.(producers: false) == materialized.([])
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
