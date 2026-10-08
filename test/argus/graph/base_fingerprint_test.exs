defmodule Argus.Graph.BaseFingerprintTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Graph.Functions
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, Memo, Runtime, Session}

  @moduletag :tmp_dir

  # One peer for the module: a fresh VM works out every query's code
  # version before it opens a graph, seconds of CPU, and each test's
  # modules and store are its own. The test of a new VM starts a
  # second one.
  setup_all do
    peer = Peer.start!()
    Peer.run(peer, fn -> Code.compiler_options(ignore_module_conflict: true) end)
    %{peer: peer}
  end

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    :ok
  end

  test "fingerprints and producer traces survive a new VM and different logical keys", %{
    peer: first,
    tmp_dir: dir
  } do
    {beam, expected} =
      Peer.run(first, fn ->
        beam = compile(1)
        session = open(dir)

        try do
          set_beam(session.db, :first, beam)
          {beam, results(session.db, :first)}
        after
          Session.close(session)
        end
      end)

    second = Peer.start!()

    Peer.run(second, fn ->
      session = open(dir)
      set_beam(session.db, :second, beam)

      try do
        {actual, computations} =
          record_computations(session.db, fn -> results(session.db, :second) end)

        assert actual == expected
        assert computations == []
      after
        Session.close(session)
      end
    end)
  end

  test "body changes affect their own fingerprint and the assembled module identity", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = open(dir)

      try do
        set_beam(session.db, :fixture, compile(1))
        before = fingerprints(session.db, :fixture)
        set_beam(session.db, :fixture, compile(2))
        after_edit = fingerprints(session.db, :fixture)

        assert before.run != after_edit.run
        assert before.unchanged == after_edit.unchanged
        assert before.module != after_edit.module
      after
        Session.close(session)
      end
    end)
  end

  test "unkeepable and legacy bases retain distinct, complete input identities", %{
    peer: peer,
    tmp_dir: dir
  } do
    Peer.run(peer, fn ->
      session = open(dir)
      key = {:fixture, {:run, 2}}
      producer_key = {key, Argus.Extractors.Purity}

      try do
        set_beam(session.db, :fixture, compile(1))
        {:ok, original} = Runtime.query(session.db, :extraction_base, key)
        expected = Runtime.query(session.db, :extraction_local, producer_key)
        {:ok, module} = Runtime.query(session.db, :extraction_module_base, :fixture)

        # A failed keep must not inherit the old prepared trace or assembly path.
        replace_base(session.db, key, %{original | base: nil})

        {actual, computations} =
          record_computations(session.db, fn ->
            Runtime.query(session.db, :extraction_local, producer_key)
          end)

        assert actual == expected
        assert length(computations) == 1
        {:ok, fallback} = Runtime.query(session.db, :extraction_module_base, :fixture)
        refute fallback.prepared?
        assert fallback.digest != module.digest

        # Values lacking the new field still recover the original content identity.
        replace_base(session.db, key, Map.delete(original, :fingerprint))

        {actual, computations} =
          record_computations(session.db, fn ->
            Runtime.query(session.db, :extraction_local, producer_key)
          end)

        assert actual == expected
        assert computations == []
        assert Runtime.query(session.db, :extraction_module_base, :fixture) == {:ok, module}
      after
        Session.close(session)
      end
    end)
  end

  defp results(db, module) do
    {fingerprints(db, module),
     Runtime.query(db, :extraction_local, {{module, {:run, 2}}, Argus.Extractors.Purity}),
     Runtime.query(db, :extraction_module_producer, {module, Argus.Extractors.ETS})}
  end

  defp fingerprints(db, module) do
    {:ok, run} = Runtime.query(db, :extraction_base, {module, {:run, 2}})
    {:ok, unchanged} = Runtime.query(db, :extraction_base, {module, {:unchanged, 1}})
    {:ok, assembled} = Runtime.query(db, :extraction_module_base, module)
    %{run: run.fingerprint, unchanged: unchanged.fingerprint, module: assembled.digest}
  end

  defp replace_base(db, key, base) do
    {:ok, entry} = Memo.get(db, {:extraction_base, key})
    value = {:ok, base}
    now = Roux.Revision.advance(db.revision, :high)

    Memo.put(db, {:extraction_base, key}, %{
      entry
      | value: value,
        hash: :erlang.phash2(value),
        changed_at: now,
        verified_at: now
    })
  end

  defp record_computations(db, fun) do
    events = :ets.new(:extraction_events, [:public, :bag])
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:argus, :graph, :extraction_compute],
        &__MODULE__.record/4,
        {events, Roux.Database.id(db)}
      )

    try do
      result = fun.()
      {result, :ets.tab2list(events)}
    after
      :telemetry.detach(handler)
      :ets.delete(events)
    end
  end

  @doc false
  def record(_, _, %{database: db, name: name}, {events, db}), do: :ets.insert(events, {name})
  def record(_, _, _, _), do: :ok

  defp open(dir) do
    Session.open(
      modules: Argus.Graph.modules() ++ [Functions, Argus.Graph.Captures],
      blob: Path.join(dir, "store")
    )
  end

  defp compile(value) do
    [{_, beam}] =
      Code.compile_string("""
      defmodule BaseFingerprintFixture do
        def run(table, key), do: :ets.lookup(table, {key, #{value}})
        def unchanged(value), do: value
      end
      """)

    beam
  end

  defp set_beam(db, key, beam),
    do: Input.set(db, :beam, key, %{data: beam, hash: Blob.digest(beam)})
end
