defmodule Argus.Graph.CodeClosureTest do
  @moduledoc """
  Each query of the graph is versioned by the code its role module
  reaches (`Roux.Code`), and roots it declares for what it reaches by
  dynamic dispatch (the extractors, the analyses): an edit to any module
  a query runs must move its version, or a manifest serves what the old
  code computed. This runs each query alone — every query it reads
  already up to date, it registered again under another version, so it
  and nothing else executes — with call counting on
  (`Roux.Code.Verify.calls/2`), cold against a store of its own so
  extraction and the solver really run, and fails if a module of argus
  or of its dependencies executed outside that closure.

  What else a query may run, each for a reason:

    * the schema's modules, which every closure leaves out because a
      query is keyed on the entries it read instead (`Argus.Graph.Reads`);
    * the `around:` hook's own code (`Argus.Graph.Reads` and what it
      reaches), which decides a query's edges, not its value, and
      versions its own queries;
    * the code a query depends on as a value (`Argus.Graph.Code`): the
      producers' (Argus.Pipeline and every extractor) when
      `producer_code` is among its dependencies, transitively, and the
      analyses' when an `analysis_code` is;
    * the graph's role modules themselves, whose generated functions
      roux calls on a dependency's behalf (its definition, its
      `transient:` predicate).

  Call counts are VM-wide: the queries run in this module's peer.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Graph.Reads
  alias Argus.Test.{Graph, Peer}
  alias Roux.Code.Verify

  @moduletag :flowlog
  @moduletag timeout: 600_000

  @analysis :coupling

  # A few modules of the parity set, among them a supervision tree the
  # coupling analysis reads.
  @modules [
    Argus.Test.Fixtures.PidFlow.CycleA,
    Argus.Test.Fixtures.PidFlow.CycleB,
    Argus.Test.Fixtures.PidFlow.Hub,
    Argus.Test.Fixtures.PidFlow.Listener
  ]

  setup_all do
    %{paths: Map.take(Graph.parity!(), @modules), peer: Peer.start!()}
  end

  test "every query executes only code its version covers", %{paths: paths, peer: peer} do
    outside = Peer.run(peer, fn -> outside(paths) end)
    assert outside == %{}
  end

  # `%{query => modules executed outside its closure}` over every query.
  defp outside(paths) do
    db = Graph.new_db(paths, store: :temporary)
    key = paths |> Map.values() |> Enum.sort() |> hd() |> Path.expand()
    program = :test

    demands = [
      {:module_beam, key},
      {:module_name, key},
      {:module_source, key},
      {:program_modules, program},
      {:module_facts, key},
      {:module_semantic, key},
      {:program_relations, program},
      {:relation, {program, :call_arg}},
      {:program_files, @analysis},
      {:program_io, @analysis},
      {:program_digest, @analysis},
      {:stage, {program, :stage0}},
      {:stage, {program, :points_to}},
      {:stage_output, {program, :stage0, "call_edge.facts"}},
      {:analysis_inputs, {program, @analysis}},
      {:solve, {program, @analysis}},
      {:findings, {program, @analysis}},
      {:extraction_errors, program},
      {:line_table, key},
      {:declaration_line, key},
      {:located, {program, @analysis}},
      {:schema_entry, "columns call_arg"},
      {:installed_specs, GenServer},
      {:producer_code, :all},
      {:analysis_code, @analysis}
    ]

    # Every query up to date first, so each run below executes its own
    # query alone.
    Enum.each(demands, fn {query, k} -> Roux.Runtime.query(db, query, k) end)

    reached = dependencies(db, demands, MapSet.new())

    demands =
      Enum.uniq_by(
        demands ++
          Enum.filter(reached, fn {name, _} ->
            String.starts_with?(Atom.to_string(name), "extraction_")
          end),
        &coverage_key/1
      )

    watched = watched()
    allowed = allowed()
    log = Roux.QueryLog.start(db)

    try do
      # Counting turned on once, and each query read with the counts set
      # back to zero.
      Verify.counting(
        fn session ->
          for {query, k} <- demands, reduce: %{} do
            acc ->
              # A store that has seen nothing: the extraction and the solve
              # run, rather than finding what they would compute.
              fresh!(db)
              definition = Roux.Database.query_definition(db, query)
              # Invalidate only this key. Changing the query's code version also
              # invalidates its other keys, which would run inside later traces.
              Roux.Dependencies.mutate(db, {query, k}, fn ->
                Roux.Dependencies.forget(db, {query, k})
                :ets.delete(db.memo_table, {query, k})
              end)

              Roux.QueryLog.reset(log)

              {_value, calls} =
                Verify.calls(session, fn -> Roux.Runtime.query(db, query, k) end)

              ran = Verify.modules(calls)

              assert k in Roux.QueryLog.executions(log, query)

              closure =
                closure(definition.module, query) |> MapSet.union(by_value(db, {query, k}))

              outside =
                Enum.reject(ran, &(MapSet.member?(closure, &1) or MapSet.member?(allowed, &1)))

              if outside == [], do: acc, else: Map.put(acc, query, outside)
          end
        end,
        modules: watched
      )
    after
      Roux.QueryLog.stop(log)
    end
  end

  defp coverage_key({:extraction_local, {_, producer}}), do: {:extraction_local, producer}

  defp coverage_key({name, {_, producer}})
       when name in [
              :extraction_module_producer,
              :extraction_metadata_rows,
              :extraction_attribute_rows,
              :extraction_producer
            ],
       do: {name, producer}

  defp coverage_key({name, _}), do: name

  # Argus's own modules, but its tests' and fixtures', and its
  # dependencies' (roux, beam_spy, ctf, pentiment, telemetry).
  defp watched do
    argus =
      for module <- Application.spec(:argus_beam, :modules),
          name = Atom.to_string(module),
          String.starts_with?(name, "Elixir.Argus."),
          not String.starts_with?(name, "Elixir.Argus.Test."),
          do: module

    deps =
      for app <- [:roux, :beam_spy, :ctf, :pentiment, :telemetry],
          module <- Application.spec(app, :modules) || [],
          do: module

    argus ++ deps
  end

  defp allowed() do
    {:ok, hook} = Roux.Code.closure([Argus.Graph.Reads])

    Application.spec(:argus_beam, :modules)
    |> Enum.filter(&Reads.schema_module?/1)
    |> Enum.concat([Argus.Graph.Reads | Enum.map(hook, &elem(&1, 0))])
    |> Enum.concat(Argus.Graph.modules())
    |> MapSet.new()
  end

  # The code a query depends on as a value: what `producer_code` and
  # `analysis_code` digest, when one is among its dependencies.
  defp by_value(db, key) do
    deps = dependencies(db, [key], MapSet.new())

    roots =
      Enum.flat_map(deps, fn
        {:producer_code, :all} -> [Argus.Pipeline | Argus.Graph.Extraction.extractors()]
        {:analysis_code, _} -> Argus.Analysis.builtin_analysis_modules()
        _other -> []
      end)

    observed =
      Enum.reduce(deps, MapSet.new(), fn key, covered ->
        {:ok, reads} = Roux.Memo.dependencies(db, key)

        Enum.reduce(reads, covered, fn
          {:query_code, query, _}, covered ->
            definition = Roux.Database.query_definition(db, query)
            MapSet.union(covered, closure(definition.module, query))

          _, covered ->
            covered
        end)
      end)

    {:ok, modules} = Roux.Code.closure(roots, exclude: &Reads.schema_module?/1)
    MapSet.union(observed, MapSet.new(modules, &elem(&1, 0)))
  end

  defp dependencies(_db, [], seen), do: seen

  defp dependencies(db, [key | rest], seen) do
    if MapSet.member?(seen, key) do
      dependencies(db, rest, seen)
    else
      deps =
        case Roux.Memo.dependencies(db, key) do
          {:ok, deps} ->
            Enum.flat_map(deps, fn
              {:parallel, _max, members} -> members
              {:input, _, _} -> []
              {:input_absent, _, _} -> []
              {:query_code, _, _} -> []
              dep -> [dep]
            end)

          :miss ->
            []
        end

      dependencies(db, deps ++ rest, MapSet.put(seen, key))
    end
  end

  # The closure a query's code version is made of: its module's, and the
  # roots it declares, the schema's modules left out.
  defp closure(module, query) do
    %{code: roots} = module.__query_definition__(query)

    roots =
      case roots do
        nil -> []
        list when is_list(list) -> list
        {m, f, a} -> apply(m, f, a)
      end

    {:ok, modules} =
      Roux.Code.closure([module | roots], exclude: &Reads.schema_module?/1)

    MapSet.new(modules, &elem(&1, 0))
  end

  # Nothing found kept: the store's action cache and traces go, so a
  # solve runs the solver and an extraction runs the extractors, while
  # its content entries stay for what the queries already computed name.
  defp fresh!(db) do
    %Roux.Blob{root: root} = db.blob
    File.rm_rf!(Path.join(root, "ac"))
    File.rm_rf!(Path.join(root, "traces"))
    :ok
  end
end
