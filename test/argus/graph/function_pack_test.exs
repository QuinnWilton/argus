defmodule Argus.Graph.FunctionPackTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Graph.Pack
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, Memo, Runtime, Session}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @moduletag skip: not Code.ensure_loaded?(Roux.Runtime.Scope)

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
        {:ok, original} = Runtime.query(db, :extraction_segments, key)
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

          {:ok, segments} = Runtime.query(db, :extraction_segments, key)
          assert List.keymember?(segments, producer, 0) == Map.has_key?(next, producer)
          expected = Enum.filter(original, fn {p, _} -> Map.has_key?(next, p) end)
          assert segments == expected
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
      assert {:ok, digest} = Memo.held_digest(session.db, key)
      File.rm!(Blob.path(session.db.blob, digest))

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

  @doc false
  def record(_, _, %{database: db, name: name}, {events, db}),
    do: :ets.insert(events, {name})

  def record(_, _, _, _), do: :ok

  defp open(dir) do
    Argus.Graph.open(
      extraction: :functions,
      reverse_dependencies: Code.ensure_loaded?(Roux.Dependencies),
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
