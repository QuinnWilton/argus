defmodule Argus.Graph.RulesTest do
  @moduledoc """
  What a warm graph runs again when argus moves and no beam does — the
  recompute sets of the plan's incrementality table:

    * a rule edit solves again only the programs that include the file
      (`dl_tree` → `program_files`), and extracts nothing;
    * a stage's rule edit derives the stage again, and nothing reading
      it runs when its outputs come out the same;
    * an edit to the code the producers run re-runs every module's
      `module_facts`, which finds every producer's rows by its trace:
      nothing is extracted, and nothing is solved;
    * an edit to one extractor runs that extractor alone in each
      module's facts, over its kept base, the others' rows taken from
      the old pack; nothing is solved when the rows come out the same;
    * an edit to code every producer runs (`Argus.Pipeline`, and what
      it reaches) extracts every module again, and solves nothing when
      the rows come out the same;
    * a schema entry that moved re-runs exactly the modules that read it;
    * an edit to the findings' prose rebuilds each analysis's findings,
      which come out the same (cutoff), and nothing past them runs;
    * a `:high` input that moves reaches only what reads it.

  A code edit is simulated by registering a query again under another
  code version, as a new build would (`Roux.Database.register_query/3`);
  a rule edit by editing a copy of argus's Datalog tree (`:dl_root`).
  The query log's telemetry handlers are VM-wide, so the graphs run in
  this module's peer (`Argus.Test.Peer`).
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Graph, Peer}
  alias Roux.{Input, Memo, QueryLog}

  @moduletag :souffle
  @moduletag timeout: 300_000

  @analyses [:coupling, :mailbox]

  setup_all do
    %{paths: Graph.parity!(), peer: Peer.start!()}
  end

  # Runs `fun` in the peer over a graph of the parity fixture solved
  # cold, with a copy of argus's Datalog tree to edit and a query log
  # attached, reset: it sees only what `fun` makes happen. `fun` takes the
  # database, the log, and the tree's root.
  defp in_graph(%{peer: peer, paths: paths}, fun) do
    Peer.run(peer, fn ->
      root = Path.join(System.tmp_dir!(), "argus_dl_#{System.unique_integer([:positive])}")
      File.cp_r!(Argus.Analysis.Catalog.priv_dl(""), root)
      Application.put_env(:panoptes, :dl_root, root)

      try do
        db = Graph.new_db(Graph.use_parity!(paths))
        log = QueryLog.start(db)
        findings!(db)
        QueryLog.reset(log)

        try do
          fun.(db, log, root)
        after
          QueryLog.stop(log)
          Roux.Database.shutdown(db)
        end
      after
        Application.delete_env(:panoptes, :dl_root)
        File.rm_rf!(root)
      end
    end)
  end

  defp findings!(db) do
    for analysis <- @analyses,
        do: {:ok, _} = Argus.Graph.Locate.located(db, {:test, analysis})

    :ok
  end

  # A declaration nothing reads: the program's text moves (a comment
  # would not: a key reads text without comment lines), and what it
  # writes does not.
  defp edit!(root, file) do
    path = Path.join(root, file)
    probe = "argus_edited_#{System.unique_integer([:positive])}"
    File.write!(path, File.read!(path) <> "\n.decl #{probe}(x: symbol)\n")
  end

  defp solved(log), do: log |> QueryLog.executions(:solve) |> Enum.map(&elem(&1, 1))
  defp staged(log), do: log |> QueryLog.executions(:stage) |> Enum.map(&elem(&1, 1))

  # Registers a query again under another code version: what a build
  # with an edit to the code it runs gives it.
  defp edit_code!(db, name) do
    definition = Roux.Database.query_definition(db, name)
    Roux.Database.register_query(db, name, %{definition | code_version: "edited"})
  end

  # The producers extraction ran, per module, while `fun` runs.
  defp extracted(fun) do
    table = :ets.new(:extracted, [:public, :bag])
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:argus, :graph, :extract],
      fn _event, _measurements, meta, table ->
        :ets.insert(table, {meta.module, meta.producers, meta.kept_base})
      end,
      table
    )

    try do
      fun.()
      :ets.tab2list(table)
    after
      :telemetry.detach(handler)
    end
  end

  test "a rule edit re-solves only the analysis it touched", context do
    in_graph(context, fn db, log, root ->
      edit!(root, "analyses/mailbox.dl")
      _moved = Argus.Graph.set_environment(db)
      findings!(db)

      assert solved(log) == [:mailbox]
      assert staged(log) == []
      assert QueryLog.executions(log, :module_facts) == []

      # The same rows: the solve comes back the same and cuts off, and
      # the findings never run.
      assert QueryLog.cutoffs(log, :solve) == [{:test, :mailbox}]
      assert QueryLog.executions(log, :findings) == []
    end)
  end

  test "a stage-0 rule edit re-derives the call graph, not the facts", context do
    in_graph(context, fn db, log, root ->
      edit!(root, "stage0.dl")
      _moved = Argus.Graph.set_environment(db)
      findings!(db)

      assert staged(log) == [:stage0]
      assert QueryLog.executions(log, :module_facts) == []
      # The same call graph: nothing reading it solves again.
      assert solved(log) == []
    end)
  end

  test "a points-to rule edit re-derives the stage, not the call graph", context do
    in_graph(context, fn db, log, root ->
      edit!(root, "points_to.dl")
      _moved = Argus.Graph.set_environment(db)
      findings!(db)

      assert staged(log) == [:points_to]
      assert solved(log) == []
      assert QueryLog.executions(log, :module_facts) == []
    end)
  end

  test "an edit to the bounded points-to program re-derives nothing while the exact one fits",
       context do
    # The stage reads the bounded program only when the exact fixpoint
    # outgrows its budget, a function of the facts: when the facts move
    # so that it does, the stage runs again and reads it then.
    in_graph(context, fn db, log, root ->
      edit!(root, "points_to_bounded.dl")
      _moved = Argus.Graph.set_environment(db)
      findings!(db)

      assert staged(log) == []
      assert solved(log) == []
    end)
  end

  test "an edit to the producers' code re-runs every module, extracts nothing, solves nothing",
       %{paths: paths} = context do
    in_graph(context, fn db, log, _root ->
      extracted = extracted(fn -> edit_code!(db, :module_facts) && findings!(db) end)

      assert length(QueryLog.executions(log, :module_facts)) == map_size(paths)
      # Every producer's rows found by its trace, every module's facts
      # the same: nothing past them runs.
      assert extracted == []
      assert QueryLog.executions(log, :module_semantic) == []
      assert staged(log) == []
      assert solved(log) == []
    end)
  end

  # Sets a query's value as if it had just come out so, at a new
  # revision: what a build with other code gives a query that reads that
  # code as a value (`Argus.Graph.Code`).
  defp came_out!(db, key, value) do
    Roux.Revision.advance(db.revision, :high)
    now = Roux.Revision.current(db.revision)
    {:ok, entry} = Memo.get(db, key)

    :ok =
      Memo.put(db, key, %{
        entry
        | value: value,
          hash: :erlang.phash2(value),
          changed_at: now,
          verified_at: now
      })
  end

  test "an edit to one extractor re-runs that extractor alone, over each module's kept base",
       %{paths: paths} = context do
    in_graph(context, fn db, log, _root ->
      {:ok, %{value: codes}} = Memo.get(db, {:producer_code, :all})
      # A digest no run has seen, or another run's trace for it would
      # hold, in the suite's store.
      edited = "edited #{System.unique_integer([:positive])} #{System.os_time()}"
      :ok = came_out!(db, {:producer_code, :all}, %{codes | Argus.Extractors.ETS => edited})

      extracted = extracted(fn -> findings!(db) end)

      assert length(QueryLog.executions(log, :module_facts)) == map_size(paths)
      # Inside each module's facts, that producer alone ran; every other
      # producer's rows came from the module's old pack.
      assert extracted |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [[Argus.Extractors.ETS]]
      assert length(extracted) == map_size(paths)
      # The same rows: nothing past them runs.
      assert QueryLog.executions(log, :module_semantic) == []
      assert solved(log) == []

      # The first extractor-only run kept each module's base; the next
      # edit runs the extractor over it, never over the beam.
      again = "#{edited} again"
      :ok = came_out!(db, {:producer_code, :all}, %{codes | Argus.Extractors.ETS => again})
      extracted = extracted(fn -> findings!(db) end)

      assert extracted |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [[Argus.Extractors.ETS]]
      assert extracted |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [true]
    end)
  end

  test "an edit to code every producer runs re-extracts every module, and solves nothing",
       %{paths: paths} = context do
    in_graph(context, fn db, log, _root ->
      {:ok, %{value: codes}} = Memo.get(db, {:producer_code, :all})
      # As an edit to `Argus.Pipeline` or to code it reaches moves every
      # producer's digest: digests no run has seen.
      run = "#{System.unique_integer([:positive])} #{System.os_time()}"
      :ok = came_out!(db, {:producer_code, :all}, Map.new(codes, &{elem(&1, 0), "edited #{run}"}))

      extracted = extracted(fn -> findings!(db) end)

      assert length(QueryLog.executions(log, :module_facts)) == map_size(paths)
      # Every producer ran on every module, from the beam.
      assert length(extracted) == map_size(paths)
      assert extracted |> Enum.map(&length(elem(&1, 1))) |> Enum.uniq() == [map_size(codes)]
      assert extracted |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [false]
      # The same rows, the same packs: nothing past them runs.
      assert QueryLog.executions(log, :module_semantic) == []
      assert staged(log) == []
      assert solved(log) == []
    end)
  end

  test "an edit to one analysis's code rebuilds its findings alone", context do
    in_graph(context, fn db, log, _root ->
      {:ok, %{value: {module, _digest}}} = Memo.get(db, {:analysis_code, :mailbox})
      :ok = came_out!(db, {:analysis_code, :mailbox}, {module, "edited"})
      findings!(db)

      assert QueryLog.executions(log, :findings) == [{:test, :mailbox}]
      # Its program's file is the same: nothing is solved again.
      assert QueryLog.executions(log, :program_files) == [:mailbox]
      assert solved(log) == []
      assert QueryLog.executions(log, :module_facts) == []
    end)
  end

  test "an edit to the findings' prose rebuilds the findings, which cut off", context do
    in_graph(context, fn db, log, _root ->
      :ok = edit_code!(db, :findings)
      findings!(db)

      assert Enum.sort(QueryLog.executions(log, :findings)) == for(a <- @analyses, do: {:test, a})
      assert QueryLog.cutoffs(log, :findings) == QueryLog.executions(log, :findings)
      assert QueryLog.executions(log, :located) == []
      assert QueryLog.executions(log, :module_facts) == []
      assert solved(log) == []
    end)
  end

  test "a schema entry that moved re-runs the modules that read it, and extracts nothing",
       %{paths: paths} = context do
    in_graph(context, fn db, log, _root ->
      read = {:schema_entry, "columns spawn_call"}

      readers =
        for key <- Map.values(paths),
            {:ok, dependencies} = Memo.dependencies(db, {:module_facts, key}),
            read in dependencies,
            do: key

      # Some of the modules, not all: the ones whose rows it holds.
      assert readers != []
      assert length(readers) < map_size(paths)

      # As if `spawn_call` had other columns when these memos were made:
      # its entry's digest then, and an argus build since.
      {:ok, entry} = Memo.get(db, read)
      :ok = Memo.put(db, read, %{entry | value: "before", hash: :erlang.phash2("before")})
      :ok = edit_code!(db, :schema_entry)

      extracted = extracted(fn -> findings!(db) end)

      assert QueryLog.executions(log, :module_facts) == Enum.sort(readers)
      # The traces recorded the entry as it is: every producer's rows hold.
      assert extracted == []
      assert solved(log) == []
    end)
  end

  test "a :high input that moves reaches only what reads it", context do
    in_graph(context, fn db, log, _root ->
      # The project root: read by every module's source, which is where it was.
      :ok = Input.set(db, :project_root, :all, "/elsewhere")
      findings!(db)

      assert QueryLog.executions(log, :module_facts) == []
      assert staged(log) == []
      assert solved(log) == []
      assert QueryLog.executions(log, :findings) == []
      assert QueryLog.executions(log, :located) == []
    end)
  end
end
