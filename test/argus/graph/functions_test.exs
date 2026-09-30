defmodule Argus.Graph.FunctionsTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Graph.Extraction
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, QueryLog, Runtime, Session}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    # Content traces create many small files. Remove them through the native
    # helper so ExUnit's next run does not queue each deletion on file_server.
    on_exit(fn -> Files.rm_rf!(dir) end)
    %{peer: Peer.start!()}
  end

  test "unrelated edits leave closure creators and bodies cached", %{peer: peer, tmp_dir: dir} do
    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true)
      session = open(dir)
      log = QueryLog.start(session.db)

      try do
        before = compile(1)
        after_edit = compile(2)
        set_beam(session.db, :fixture, before)
        demand(session.db, :fixture)
        QueryLog.reset(log)
        set_beam(session.db, :fixture, after_edit)
        actual = demand(session.db, :fixture)
        assert QueryLog.executions(log, :extraction_base) == [{:fixture, {:numeric, 1}}]

        assert Enum.all?(QueryLog.executions(log, :extraction_local), fn
                 {{:fixture, {:numeric, 1}}, _} -> true
                 _ -> false
               end)

        assert_same(actual, fresh(after_edit))
      after
        QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  # Keep all fixture comparisons while bounding each test's work under suite
  # contention. Each partition still exercises several modules in one session.
  for partition <- 0..3 do
    @partition partition

    test "function queries preserve closure and cross-function facts, partition #{partition}", %{
      peer: peer,
      tmp_dir: dir
    } do
      Peer.run(peer, fn ->
        session = open(dir)

        try do
          paths =
            Path.wildcard("_build/test/lib/argus_beam/ebin/Elixir.Argus.Test.Fixtures.*.beam")
            |> Enum.filter(fn path ->
              String.contains?(path, ["RpcTarget.", "GenStatem", "SameLine", "CheckThenAct."])
            end)
            |> Enum.with_index()
            |> Enum.filter(fn {_path, index} -> rem(index, 4) == @partition end)

          assert length(paths) > 10

          for {path, _index} <- paths do
            set_beam(session.db, path, File.read!(path))
            assert_same(demand(session.db, path), fresh(path))
          end
        after
          Session.close(session)
        end
      end)
    end
  end

  test "content traces reuse extraction across logical module keys without a manifest", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      beam = compile(1)
      first = open(dir)
      set_beam(first.db, :first_project, beam)
      expected = demand(first.db, :first_project)
      Session.close(first)

      second = open(dir)
      set_beam(second.db, :second_project, beam)
      events = :ets.new(:extraction_events, [:public, :bag])
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:argus, :graph, :extraction_compute],
          &__MODULE__.record/4,
          {events, Roux.Database.id(second.db)}
        )

      try do
        assert demand(second.db, :second_project) == expected
        assert :ets.tab2list(events) == []
      after
        :telemetry.detach(handler)
        :ets.delete(events)
        Session.close(second)
      end
    end)
  end

  test "closure additions, reordering, captures and recursion preserve fresh results", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true)
      session = open(dir)

      variants = [
        "fn -> :erpc.call(node, mod, fun, args) end",
        "{fn x -> x end, fn -> :erpc.call(node, mod, fun, args) end}",
        "{fn -> :erpc.call(node, mod, fun, args) end, fn x -> x end}",
        "fn -> :timer.tc(fn -> :erpc.call(node, mod, fun, args) end) end",
        "fn x -> {x, args, fun, mod, node} end",
        "fn recur, n -> if n == 0, do: :erpc.call(node, mod, fun, args), else: recur.(recur, n - 1) end",
        "{node, mod, fun, args}"
      ]

      try do
        for body <- variants ++ Enum.reverse(variants) do
          [{_, beam}] =
            Code.compile_string("""
            defmodule ClosureEditFixture do
              def build(node, mod, fun, args), do: #{body}
            end
            """)

          set_beam(session.db, :closure_edit, beam)
          assert_same(demand(session.db, :closure_edit), fresh(beam))
        end
      after
        Session.close(session)
      end
    end)
  end

  test "a graph preparation edit invalidates content traces", %{peer: peer, tmp_dir: dir} do
    Peer.run(peer, fn ->
      session = open(dir)
      db = session.db
      set_beam(db, :fixture, compile(1))
      key = {{:fixture, {:numeric, 1}}, Argus.Extractors.Purity}
      expected = Runtime.query(db, :extraction_local, key)
      events = :ets.new(:extraction_events, [:public, :bag])
      handler = make_ref()

      :telemetry.attach(
        handler,
        [:argus, :graph, :extraction_compute],
        &__MODULE__.record/4,
        {events, Roux.Database.id(db)}
      )

      try do
        definition = Roux.Database.query_definition(db, :extraction_local)

        Roux.Database.register_query(db, :extraction_local, %{
          definition
          | code_version: "changed preparation"
        })

        assert Runtime.query(db, :extraction_local, key) == expected
        assert [{_trace}] = :ets.tab2list(events)
      after
        :telemetry.detach(handler)
        :ets.delete(events)
        Session.close(session)
      end
    end)
  end

  @doc false
  def record(_, _, %{database: db, name: name}, {events, db}),
    do: :ets.insert(events, {name})

  def record(_, _, _, _), do: :ok

  defp open(dir) do
    opts = [
      modules: Argus.Graph.modules(),
      blob: Path.join(dir, "store")
    ]

    Session.open(opts)
  end

  defp compile(number) do
    [{_, beam}] =
      Code.compile_string("""
      defmodule FunctionQueryFixture do
        def first(table), do: fn key -> :ets.lookup(table, key) end
        def second(table), do: fn key -> :ets.delete(table, key) end
        def rpc(node, mod, fun, args), do: :timer.tc(fn -> :erpc.call(node, mod, fun, args) end)
        def numeric(x), do: x + #{number}
      end
      """)

    beam
  end

  defp set_beam(db, key, bytes),
    do: Input.set(db, :beam, key, %{data: bytes, hash: Blob.digest(bytes)})

  defp demand(db, key) do
    Map.new(Extraction.extractors(), fn producer ->
      {:ok, rows} = Runtime.query(db, :extraction_producer, {key, producer})
      {producer, rows}
    end)
  end

  defp fresh(beam) do
    {:ok, extraction} =
      Argus.Pipeline.extract_module(beam,
        producers: Extraction.extractors(),
        trace_imprecision: true
      )

    extraction.facts
  end

  defp assert_same(actual, expected) do
    sets = fn rows ->
      Map.new(rows, fn {producer, facts} ->
        {producer,
         Map.new(facts, fn {relation, bytes} ->
           {relation, bytes |> Argus.Tsv.decode() |> MapSet.new()}
         end)}
      end)
    end

    assert sets.(actual) == sets.(expected)
  end
end
