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
    * nothing past the modules' facts reads the producers' code, so an
      edit to it reaches a solve only through facts that come out
      different;
    * a schema code change checks module traces against the entries they read;
    * an edit to the findings' prose rebuilds each analysis's findings,
      which come out the same (cutoff), and nothing past them runs;
    * a `:high` input that moves reaches only what reads it.

  A code edit is simulated by registering a query again under another
  code version, as a new build would (`Roux.Database.register_query/3`);
  a rule edit by editing a copy of argus's Datalog tree (`:dl_root`).
  The query log's telemetry handlers are VM-wide, so the graphs run in
  this module's peer (`Argus.Test.Peer`).

  The edits to extraction code, which run over a store of their own,
  stop at the program's relations and never solve: a cold solve there
  is most of such a check's run, and its edits solve nothing. A solve's
  inputs are those relations' digests, and nothing past the modules'
  facts reads the producers' code (checked on its own): such an edit
  reaches a solve only through facts that come out different. So
  "nothing past the facts runs, and the relations are as they were" is
  "solves nothing", as the producers' code check shows down to the
  solves.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.Fixtures.{LeakedTaskModule, PidFlow, Restart}
  alias Argus.Test.{Graph, Peer}
  alias Roux.{Input, Memo, QueryLog}

  @moduletag :flowlog
  @moduletag timeout: 300_000

  @analyses [:coupling, :mailbox]

  setup_all do
    # A coupling defect with real ETS rows, a leaked task, and a module
    # that reads spawn_call's schema. The separate parity gate covers
    # every analysis over the full fixture set.
    modules = [
      Restart.HookSup,
      Restart.HookKeeper,
      Restart.HookUser,
      LeakedTaskModule,
      PidFlow.Loops
    ]

    paths = Map.new(modules, &{&1, &1 |> :code.which() |> List.to_string()})
    %{paths: paths, peer: Peer.start!()}
  end

  # Runs `fun` in the peer over a graph of the fixtures solved
  # cold, with a copy of argus's Datalog tree to edit and a query log
  # attached, reset: it sees only what `fun` makes happen. `fun` takes the
  # database, the log, and the tree's root. The database takes the
  # context's `db_opts` (`Argus.Test.Graph.new_db/2`); with `cold:
  # :relations` the cold run stops at the program's relations, unsolved.
  defp in_graph(%{peer: peer, paths: paths} = context, fun) do
    opts = Map.get(context, :db_opts, [])
    cold = Map.get(context, :cold, :findings)

    Peer.run(peer, fn ->
      root = Path.join(System.tmp_dir!(), "argus_dl_#{System.unique_integer([:positive])}")
      File.cp_r!(Argus.Dl.path(""), root)
      Application.put_env(:argus_beam, :dl_root, root)

      try do
        db = Graph.new_db(paths, opts)
        log = QueryLog.start(db)
        if cold == :relations, do: relations!(db), else: findings!(db)
        QueryLog.reset(log)

        try do
          fun.(db, log, root)
        after
          QueryLog.stop(log)
          Roux.Database.shutdown(db)
        end
      after
        Application.delete_env(:argus_beam, :dl_root)
        File.rm_rf!(root)
      end
    end)
  end

  defp findings!(db) do
    for analysis <- @analyses do
      assert {:ok, [_ | _]} = Argus.Graph.Locate.located(db, {:test, analysis}),
             "#{analysis} must have findings for the invalidation checks"
    end

    :ok
  end

  # The digest of each relation the program's modules have rows for: what
  # a solve's inputs are named by (`Argus.Graph.Relations`).
  defp relations!(db) do
    relations = Roux.Runtime.query(db, :program_relations, :test)
    assert [_ | _] = Map.keys(relations)
    relations
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
      [:argus, :graph, :extraction_compute],
      fn _event, _measurements, meta, table ->
        :ets.insert(table, {meta.module, meta.producer})
      end,
      table
    )

    try do
      fun.()

      table
      |> :ets.tab2list()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {module, producers} ->
        {module, Enum.sort(producers), :base not in producers}
      end)
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

  test "nothing past the modules' facts reads the producers' code", context do
    in_graph(context, fn db, _log, _root ->
      graph = Memo.reduce_dependencies(db, %{}, fn key, deps, acc -> Map.put(acc, key, deps) end)

      roots =
        for {{query, _} = key, _} <- graph,
            query in [:solve, :stage, :findings, :located],
            do: key

      reached = reach(graph, roots, MapSet.new())

      assert Enum.any?(roots, &match?({:solve, _}, &1))
      assert Enum.any?(reached, &match?({:module_facts, _}, &1))

      refute MapSet.member?(reached, {:producer_code, :all}),
             "a solve, a stage or the findings read the producers' code past the modules' facts"

      # Nor do they read the in-process facts, which a module's facts
      # leave out.
      refute Enum.any?(reached, &match?({:module_in_process, _}, &1)),
             "a solve, a stage or the findings read the modules' in-process facts"
    end)
  end

  # What `keys` read, and what that reads, not past a module's facts.
  defp reach(_graph, [], seen), do: seen

  defp reach(graph, [key | rest], seen) do
    cond do
      MapSet.member?(seen, key) ->
        reach(graph, rest, seen)

      match?({query, _} when query in [:module_facts, :module_in_process], key) ->
        reach(graph, rest, MapSet.put(seen, key))

      true ->
        reach(graph, Map.get(graph, key, []) ++ rest, MapSet.put(seen, key))
    end
  end

  # Sets a query's value as if it had just come out so, at a new
  # revision: what a build with other code gives a query that reads that
  # code as a value (`Argus.Graph.Code`).
  defp came_out!(db, key, value) do
    Roux.Dependencies.mutate(db, key, fn ->
      now = Roux.Dependencies.advance(db, :high)
      {:ok, entry} = Memo.get(db, key)

      Roux.Memo.publish(
        db,
        key,
        %{entry | value: value, hash: :erlang.phash2(value), changed_at: now, verified_at: now},
        false,
        :restored
      )
    end)

    :ok
  end

  # The code digests these edits make up are no build's: in the suite's
  # store, the variants and bases they keep would push out the real ones
  # each module's trace keeps (four of each producer's, two bases), and a
  # later run would extract again what it had. They run over a store of
  # their own.
  test "an edit to one extractor re-runs that extractor alone, over each module's kept base",
       %{paths: paths} = context do
    context = Map.merge(context, %{db_opts: [store: :temporary], cold: :relations})

    in_graph(context, fn db, log, _root ->
      assert [_ | _] = Argus.Graph.Relations.rows(db, :test, :ets_new)
      relations = relations!(db)
      {:ok, %{value: codes}} = Memo.get(db, {:producer_code, :all})
      edited = "edited #{System.unique_integer([:positive])} #{System.os_time()}"
      :ok = came_out!(db, {:producer_code, :all}, %{codes | Argus.Extractors.ETS => edited})

      extracted = extracted(fn -> relations!(db) end)

      assert length(QueryLog.executions(log, :module_facts)) == map_size(paths)
      # Inside each module's facts, that producer alone ran, over the base
      # the cold run kept, never over the beam; every other producer's
      # rows came from its segment.
      assert extracted |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [[Argus.Extractors.ETS]]
      assert extracted |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [true]
      assert length(extracted) == map_size(paths)
      # The same rows: nothing past them runs, and a solve's inputs are
      # as they were.
      assert QueryLog.executions(log, :module_semantic) == []
      assert relations!(db) == relations

      # The next edit too.
      again = "#{edited} again"
      :ok = came_out!(db, {:producer_code, :all}, %{codes | Argus.Extractors.ETS => again})
      extracted = extracted(fn -> relations!(db) end)

      assert extracted |> Enum.map(&elem(&1, 1)) |> Enum.uniq() == [[Argus.Extractors.ETS]]
      assert extracted |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [true]

      # Undone, the edit finds the rows the code made before, and runs
      # nothing.
      :ok = came_out!(db, {:producer_code, :all}, %{codes | Argus.Extractors.ETS => edited})
      assert extracted(fn -> relations!(db) end) == []
    end)
  end

  test "an edit to code every producer runs re-extracts every module, and solves nothing",
       %{paths: paths} = context do
    context = Map.merge(context, %{db_opts: [store: :temporary], cold: :relations})

    in_graph(context, fn db, log, _root ->
      relations = relations!(db)
      {:ok, %{value: codes}} = Memo.get(db, {:producer_code, :all})
      # As an edit to `Argus.Pipeline` or to code it reaches moves every
      # producer's digest: digests no run has seen.
      run = "#{System.unique_integer([:positive])} #{System.os_time()}"
      :ok = came_out!(db, {:producer_code, :all}, Map.new(codes, &{elem(&1, 0), "edited #{run}"}))

      extracted = extracted(fn -> relations!(db) end)

      assert length(QueryLog.executions(log, :module_facts)) == map_size(paths)
      # Every applicable producer ran from the beam. Selectors need no local
      # queries for functions that cannot emit any of their facts.
      assert length(extracted) == map_size(paths)

      for {module, producers, _kept_base} <- extracted do
        {:ok, data} = Roux.Runtime.query(db, :extraction_index, paths[module])

        expected =
          for producer <- Map.keys(codes),
              Enum.any?(data.functions, fn {key, {:function, _, _, _, instructions}} ->
                (not function_exported?(producer, :candidate?, 1) or
                   producer.candidate?(key)) and
                  (not function_exported?(producer, :candidate_instructions?, 1) or
                     producer.candidate_instructions?(instructions))
              end),
              do: producer

        assert producers == Enum.sort(expected)
      end

      assert extracted |> Enum.map(&elem(&1, 2)) |> Enum.uniq() == [false]
      # The same rows, the same packs: nothing past them runs, and a
      # solve's inputs are as they were.
      assert QueryLog.executions(log, :module_semantic) == []
      assert relations!(db) == relations
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

  test "a schema code change rechecks module proofs without extracting facts",
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

      Roux.Dependencies.mutate(db, read, fn ->
        Memo.publish(
          db,
          read,
          %{entry | value: "before", hash: :erlang.phash2("before")},
          false,
          :restored
        )
      end)

      :ok = edit_code!(db, :schema_entry)

      extracted = extracted(fn -> findings!(db) end)

      assert QueryLog.executions(log, :module_facts) == Enum.sort(Map.values(paths))
      assert QueryLog.executions(log, :extraction_pack) == []
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
