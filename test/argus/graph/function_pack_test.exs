defmodule Argus.Graph.FunctionPackTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Graph.Pack
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, Memo, Runtime, Session}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    %{peer: Peer.start!()}
  end

  test "producer additions and removals update packs when other digests stay equal", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = open(dir)
      db = session.db
      set_beam(db, compile(1))
      key = {:fixture, :extracted}

      try do
        {:ok, original_pack, _held} = Runtime.query(db, :extraction_pack, key)
        {:ok, original} = Blob.get_term(db.blob, original_pack.pack)
        {:ok, %{value: codes}} = Memo.get(db, {:producer_code, :all})
        producer = Argus.Extractors.ETS
        assert List.keymember?(original, producer, 0)

        for next <- [Map.delete(codes, producer), codes] do
          Roux.Revision.advance(db.revision, :high)
          now = Roux.Revision.current(db.revision)
          {:ok, entry} = Memo.get(db, {:producer_code, :all})

          Memo.put(db, {:producer_code, :all}, %{
            entry
            | value: next,
              hash: :erlang.phash2(next),
              changed_at: now,
              verified_at: now
          })

          {:ok, pack, held} = Runtime.query(db, :extraction_pack, key)
          {:ok, index} = Blob.get_term(db.blob, pack.pack)
          assert Enum.all?(held, &Blob.member?(db.blob, &1))
          assert List.keymember?(index, producer, 0) == Map.has_key?(next, producer)
          expected = Enum.filter(original, fn {p, _, _} -> Map.has_key?(next, p) end)
          assert index == expected
        end
      after
        Session.close(session)
      end
    end)
  end

  test "a timeout during validation replaces old facts and retries after reopening", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true)
      session = open(dir)
      set_beam(session.db, compile(1))
      assert {:ok, %{lost: false}} = Runtime.query(session.db, :module_facts, :fixture)

      set_beam(session.db, compile(2))
      Application.put_env(:argus_beam, :extraction_timeout, 0)
      assert {:ok, %{lost: true} = lost} = Runtime.query(session.db, :module_facts, :fixture)

      assert {:ok, %{extraction_error: bytes}} =
               Pack.chunks(session.db.blob, lost.pack, [:extraction_error])

      assert bytes =~ "extraction did not finish within 0 ms"
      assert {:ok, %{persist: :transient}} = Memo.get(session.db, {:module_facts, :fixture})
      Session.commit(session, %{})
      Session.close(session)

      Application.delete_env(:argus_beam, :extraction_timeout)
      restored = open(dir)
      assert restored.restored?
      assert :miss = Memo.get(restored.db, {:module_facts, :fixture})
      assert {:ok, %{lost: false}} = Runtime.query(restored.db, :module_facts, :fixture)
      Session.close(restored)
    end)
  end

  test "missing pack segments are reproduced from function results", %{peer: peer, tmp_dir: dir} do
    Peer.run(peer, fn ->
      session = open(dir)
      set_beam(session.db, compile(1))
      {:ok, pack} = Runtime.query(session.db, :module_facts, :fixture)
      {:ok, chunks} = Pack.chunks(session.db.blob, pack.pack, [:function_def])
      {:ok, index} = Blob.get_term(session.db.blob, pack.pack)
      [{:base, segment, _} | _] = index
      File.rm!(Blob.path(session.db.blob, segment))
      assert :ok = Pack.restore(session.db, {:module_facts, :fixture}, pack.pack)
      assert Pack.chunks(session.db.blob, pack.pack, [:function_def]) == {:ok, chunks}
      Session.close(session)
    end)
  end

  test "restored roots use the module proof without visiting function memos", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      first = open(dir)
      set_beam(first.db, compile(1))
      facts = Runtime.query(first.db, :module_facts, :fixture)
      in_process = Runtime.query(first.db, :module_in_process, :fixture)
      Session.commit(first, %{})
      Session.close(first)

      restored = open(dir)
      assert restored.restored?
      log = Roux.QueryLog.start(restored.db)

      try do
        assert Runtime.query(restored.db, :module_facts, :fixture) == facts
        assert Runtime.query(restored.db, :module_in_process, :fixture) == in_process

        for query <- [:extraction_pack, :extraction_function, :extraction_base] do
          assert Roux.QueryLog.executions(log, query) == []
          assert Roux.QueryLog.hits(log, query) == []
        end

        assert {:ok, deps} = Memo.dependencies(restored.db, {:module_facts, :fixture})
        refute {:extraction_pack, {:fixture, :extracted}} in deps
        assert Enum.any?(deps, &match?({:query_code, :extraction_pack, _}, &1))

        assert {:unchanged, _} = Session.commit(restored, %{})
        again = open(dir)

        try do
          assert Runtime.query(again.db, :module_facts, :fixture) == facts
          assert Runtime.query(again.db, :module_in_process, :fixture) == in_process
          assert {:unchanged, _} = Session.commit(again, %{})
        after
          Session.close(again)
        end

        Roux.QueryLog.reset(log)
        Input.set(restored.db, :beam, :unrelated, %{data: <<>>, hash: Blob.digest(<<>>)})
        assert Runtime.query(restored.db, :module_facts, :fixture) == facts
        assert Roux.QueryLog.executions(log, :module_facts) == []
      after
        Roux.QueryLog.stop(log)
        Session.close(restored)
      end
    end)
  end

  test "compact descriptors repair lost indexes and segments after reopening", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      first = open(dir)
      set_beam(first.db, compile(1))

      expected =
        for query <- [:module_facts, :module_in_process] do
          {:ok, pack} = Runtime.query(first.db, query, :fixture)
          {:ok, chunks} = Pack.chunks(first.db.blob, pack.pack, Map.keys(pack.relations))
          {query, pack, chunks}
        end

      Session.commit(first, %{})
      Session.close(first)
      restored = open(dir)

      try do
        for {query, pack, chunks} <- expected do
          {:ok, index} = Blob.get_term(restored.db.blob, pack.pack)
          segments = Enum.map(index, &elem(&1, 1))

          for removed <- [[pack.pack], Enum.take(segments, 1), [pack.pack | segments]] do
            for digest <- Enum.uniq(removed), do: File.rm!(Blob.path(restored.db.blob, digest))

            assert Pack.read_chunks(
                     restored.db,
                     query,
                     :fixture,
                     pack.pack,
                     Map.keys(pack.relations)
                   ) == {:ok, chunks}

            assert Enum.all?(removed, &Blob.member?(restored.db.blob, &1))
          end
        end
      after
        Session.close(restored)
      end
    end)
  end

  test "manifest and content traces survive a fresh VM", %{peer: first, tmp_dir: dir} do
    expected =
      Peer.run(first, fn ->
        beam = compile(1)
        File.write!(Path.join(dir, "fixture.beam"), beam)
        session = open(dir)
        set_beam(session.db, beam)
        {:ok, pack} = Runtime.query(session.db, :module_facts, :fixture)
        Session.commit(session, %{})
        Session.close(session)
        pack
      end)

    second = Peer.start!()

    Peer.run(second, fn ->
      session = open(dir)
      assert session.restored?
      assert Runtime.query(session.db, :module_facts, :fixture) == {:ok, expected}
      key = {:extraction_base, {:fixture, {:run, 2}}}
      assert {:ok, locator} = Memo.held_locator(session.db, key)

      for digest <- Roux.Memo.Value.roots(locator) do
        File.rm!(Blob.path(session.db.blob, digest))
      end

      assert {:ok, %{base: base}} =
               Runtime.query(session.db, :extraction_base, {:fixture, {:run, 2}})

      assert is_binary(base)
      Session.close(session)

      File.rm!(Path.join(dir, "manifest"))
      session = open(dir)
      set_beam(session.db, File.read!(Path.join(dir, "fixture.beam")))
      events = :ets.new(:extraction_events, [:public, :bag])
      handler = make_ref()

      :telemetry.attach(
        handler,
        [:argus, :graph, :extraction_compute],
        &__MODULE__.record/4,
        {events, Roux.Database.id(session.db)}
      )

      try do
        assert Runtime.query(session.db, :module_facts, :fixture) == {:ok, expected}
        assert :ets.tab2list(events) == []
      after
        :telemetry.detach(handler)
        :ets.delete(events)
        Session.close(session)
      end
    end)
  end

  test "reverting a module reuses its pack without visiting function queries", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true)
      session = open(dir)
      db = session.db
      first = compile(1)
      second = compile(2)
      log = Roux.QueryLog.start(db)

      try do
        set_beam(db, first)
        facts = Runtime.query(db, :module_facts, :fixture)
        in_process = Runtime.query(db, :module_in_process, :fixture)
        {:ok, entry} = Memo.get(db, {:module_facts, :fixture})
        assert hd(entry.dependencies) == {:module_beam, :fixture}
        assert Enum.any?(entry.dependencies, &match?({:schema_entry, _}, &1))

        set_beam(db, second)
        assert Runtime.query(db, :module_facts, :fixture) != facts
        Runtime.query(db, :module_in_process, :fixture)
        set_beam(db, first)
        Roux.QueryLog.reset(log)

        assert Runtime.query(db, :module_facts, :fixture) == facts
        assert Runtime.query(db, :module_in_process, :fixture) == in_process
        assert Roux.QueryLog.executions(log, :extraction_pack) == []
        assert Roux.QueryLog.hits(log, :extraction_pack) == []
        assert Roux.QueryLog.executions(log, :extraction_function) == []
        assert Roux.QueryLog.hits(log, :extraction_function) == []
      after
        Roux.QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  test "a saved module trace rejects missing blobs and changed observations", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      Code.compiler_options(ignore_module_conflict: true)
      session = open(dir)
      db = session.db
      first = compile(1)
      second = compile(2)
      log = Roux.QueryLog.start(db)

      try do
        set_beam(db, first)
        {:ok, pack} = Runtime.query(db, :module_facts, :fixture)
        {:ok, entry} = Memo.get(db, {:module_facts, :fixture})
        schema = Enum.find(entry.dependencies, &match?({:schema_entry, _}, &1))

        set_beam(db, second)
        Runtime.query(db, :module_facts, :fixture)
        File.rm!(Blob.path(db.blob, pack.pack))
        set_beam(db, first)
        Roux.QueryLog.reset(log)
        assert Runtime.query(db, :module_facts, :fixture) == {:ok, pack}
        assert Roux.QueryLog.executions(log, :extraction_pack) != []
        assert Blob.member?(db.blob, pack.pack)

        set_beam(db, second)
        Runtime.query(db, :module_facts, :fixture)
        {:ok, entry} = Memo.get(db, schema)
        now = Roux.Revision.current(db.revision)

        Memo.put(db, schema, %{
          entry
          | value: "changed schema observation",
            hash: 0,
            changed_at: now,
            verified_at: now
        })

        set_beam(db, first)
        Roux.QueryLog.reset(log)
        assert Runtime.query(db, :module_facts, :fixture) == {:ok, pack}
        assert Roux.QueryLog.executions(log, :extraction_pack) != []
      after
        Roux.QueryLog.stop(log)
        Session.close(session)
      end
    end)
  end

  @doc false
  def record(_, _, %{database: db, name: name}, {events, db}),
    do: :ets.insert(events, {name})

  def record(_, _, _, _), do: :ok

  defp open(dir) do
    Argus.Graph.open(
      store: Path.join(dir, "store"),
      manifest: Path.join(dir, "manifest")
    )
  end

  defp set_beam(db, bytes),
    do: Input.set(db, :beam, :fixture, %{data: bytes, hash: Blob.digest(bytes)})

  defp compile(value) do
    [{_, bytes}] =
      Code.compile_string("""
      defmodule FunctionPackFixture do
        def run(table, key), do: :ets.lookup(table, {key, #{value}})
        def closure(table), do: fn key -> :ets.delete(table, key) end
      end
      """)

    bytes
  end
end
