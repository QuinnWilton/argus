defmodule Argus.Graph.ModuleTraceTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Graph.Pack
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Database, Input, Memo, QueryLog, Runtime, Session}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @callee ModuleTraceSpecFixture.Callee

  # One peer for the module: a fresh VM works out every query's code
  # version before it opens a graph, seconds of CPU, and each test's
  # modules and store are its own.
  setup_all do
    peer = Peer.start!()
    Peer.run(peer, fn -> Code.compiler_options(ignore_module_conflict: true) end)
    %{peer: peer}
  end

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    :ok
  end

  test "a whole-module hit tracks installed specs in a fresh session", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      ebin = Path.join(dir, "ebin")
      File.mkdir_p!(ebin)
      Code.prepend_path(ebin)
      callee = compile_callee(ebin, ":ok")
      beam = compile_caller()
      watch = &watch(&1, callee)
      expected = seed(dir, beam, watch)
      session = open(dir)
      db = session.db
      set_beam(db, beam)
      watch.(db)
      log = QueryLog.start(db)

      try do
        assert Runtime.query(db, :module_facts, :fixture) == {:ok, expected}
        assert QueryLog.executions(log, :extraction_pack) == []
        assert :miss = Memo.get(db, {:extraction_disassembly, :fixture})
        assert shapes(db, expected) == ["constant", "total"]
        assert {:ok, deps} = Memo.dependencies(db, {:module_facts, :fixture})
        assert {:installed_specs, @callee} in deps

        compile_callee(ebin, ":ok | {:error, term()}")
        watch.(db)
        QueryLog.reset(log)
        {:ok, changed} = Runtime.query(db, :module_facts, :fixture)
        assert shapes(db, changed) == ["can_fail"]
        assert @callee in QueryLog.executions(log, :installed_specs)
        assert QueryLog.executions(log, :extraction_pack) != []
        assert changed == seed(Path.join(dir, "fresh"), beam, watch)
      after
        QueryLog.stop(log)
        Session.close(session)
        Code.delete_path(ebin)
      end
    end)
  end

  test "a whole-module hit rejects a changed extraction query version", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      beam = compile(1)
      expected = seed(dir, beam)
      session = open(dir)
      db = session.db
      set_beam(db, beam)
      log = QueryLog.start(db)

      try do
        assert Runtime.query(db, :module_facts, :fixture) == {:ok, expected}
        assert QueryLog.executions(log, :extraction_pack) == []
        assert :miss = Memo.get(db, {:extraction_disassembly, :fixture})

        definition = Database.query_definition(db, :extraction_local)

        Database.register_query(db, :extraction_local, %{
          definition
          | code_version: "changed extraction query"
        })

        QueryLog.reset(log)
        assert Runtime.query(db, :module_facts, :fixture) == {:ok, expected}
        assert QueryLog.executions(log, :extraction_pack) != []
        assert QueryLog.executions(log, :extraction_local) != []
      after
        QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  test "a missing segment is repaired after a hit with no function memos", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      beam = compile(1)
      expected = seed(dir, beam)
      session = open(dir)
      db = session.db
      set_beam(db, beam)
      log = QueryLog.start(db)

      try do
        assert Runtime.query(db, :module_facts, :fixture) == {:ok, expected}
        assert QueryLog.executions(log, :extraction_pack) == []
        assert :miss = Memo.get(db, {:extraction_disassembly, :fixture})
        assert :miss = Memo.get(db, {:extraction_base, {:fixture, {:run, 1}}})
        {:ok, rows} = Pack.chunks(db.blob, expected.pack, [:function_def])
        {:ok, index} = Blob.get_term(db.blob, expected.pack)
        {:base, segment, _relations} = List.keyfind(index, :base, 0)
        File.rm!(Blob.path(db.blob, segment))

        assert Pack.read_chunks(db, :module_facts, :fixture, expected.pack, [:function_def]) ==
                 {:ok, rows}

        assert Blob.member?(db.blob, segment)
        assert QueryLog.executions(log, :extraction_base_rows) != []
      after
        QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  test "an input change during identity reads cannot publish under the old beam", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      first = compile(1)
      second = compile(2)
      expected = seed(Path.join(dir, "oracle"), first)
      session = open(dir)
      db = session.db
      set_beam(db, first)
      once = :ets.new(:identity_change, [:public, :set])
      handler = make_ref()

      :telemetry.attach(handler, [:roux, :query, :stop], &__MODULE__.change_beam/4, {
        db,
        second,
        once
      })

      try do
        Runtime.query(db, :module_facts, :fixture)
        assert :ets.member(once, :changed)
      after
        :telemetry.detach(handler)
        :ets.delete(once)
        Session.close(session)
      end

      assert seed(dir, first) == expected
    end)
  end

  @doc false
  def change_beam(_, _, %{query_name: :producer_code, database: id}, {db, beam, once}) do
    if id == Database.id(db) and :ets.insert_new(once, {:changed}) do
      set_beam(db, beam)
    end
  end

  def change_beam(_, _, _, _), do: :ok

  defp open(dir) do
    session = Argus.Graph.open(store: Path.join(dir, "store"))
    Argus.Graph.set_environment(session.db, stamps: false)
    session
  end

  defp seed(dir, beam, prepare \\ fn _db -> :ok end) do
    session = open(dir)

    try do
      set_beam(session.db, beam)
      prepare.(session.db)
      {:ok, pack} = Runtime.query(session.db, :module_facts, :fixture)
      pack
    after
      Session.close(session)
    end
  end

  defp set_beam(db, beam),
    do: Input.set(db, :beam, :fixture, %{data: beam, hash: Blob.digest(beam)})

  defp watch(db, path) do
    {key, value} = Argus.Graph.beam_input(path)
    Input.set(db, :beam, key, value)
  end

  defp compile(value) do
    [{_, beam}] =
      Code.compile_string("""
      defmodule ModuleTraceFixture do
        def run(table), do: :ets.lookup(table, #{value})
      end
      """)

    beam
  end

  defp compile_callee(ebin, returns) do
    previous = Code.compiler_options(debug_info: true, ignore_module_conflict: true)

    try do
      [{module, beam}] =
        Code.compile_string("""
        defmodule #{inspect(@callee)} do
          @spec put(term()) :: #{returns}
          def put(_value), do: :ok
        end
        """)

      path = Path.join(ebin, "#{module}.beam")
      File.write!(path, beam)
      :code.purge(module)
      :code.delete(module)
      :code.purge(module)
      path
    after
      Code.compiler_options(previous)
    end
  end

  defp compile_caller do
    [{_, beam}] =
      Code.compile_string("""
      defmodule ModuleTraceSpecFixture.Caller do
        def run(value), do: #{inspect(@callee)}.put(value)
      end
      """)

    beam
  end

  defp shapes(db, pack) do
    {:ok, %{spec_return: bytes}} = Pack.chunks(db.blob, pack.pack, [:spec_return])

    for(
      [function, shape, "installed"] <- Argus.Tsv.decode(bytes),
      String.starts_with?(function, inspect(@callee) <> ":"),
      do: shape
    )
    |> Enum.sort()
  end
end
