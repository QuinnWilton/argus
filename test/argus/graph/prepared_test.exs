defmodule Argus.Graph.PreparedTest do
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Graph.{Extraction, Functions}
  alias Argus.Test.{Files, Peer}
  alias Roux.{Blob, Input, Memo, Runtime, Session}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> Files.rm_rf!(dir) end)
    :ok
  end

  test "encoded row merging preserves escapes, empty fields, and empty rows" do
    rows = [["a\tb", "x\ny"], ["\\n", "\r"], ["", ""], [""], ["z", "a"]]
    bytes = rows |> Argus.Tsv.encode() |> IO.iodata_to_binary()
    merged = Functions.merge_rows([%{test: bytes}, %{test: "\n"}, %{test: bytes}])

    assert MapSet.new(Argus.Tsv.decode(merged.test)) == MapSet.new(rows)
    assert merged == Functions.merge_rows([merged, %{test: bytes}])
  end

  test "an unkeepable base falls back to guarded extraction", %{tmp_dir: dir} do
    peer = Peer.start!()

    Peer.run(peer, fn ->
      [{module, beam}] =
        Code.compile_string("""
        defmodule UnkeepableBaseFixture do
          def run(table, key), do: :ets.lookup(table, key)
        end
        """)

      session =
        Session.open(
          modules: Argus.Graph.modules() ++ [Functions, Argus.Graph.Captures],
          blob: Path.join(dir, "store")
        )

      try do
        db = session.db
        Input.set(db, :beam, module, %{data: beam, hash: Blob.digest(beam)})
        key = {module, {:run, 2}}
        Runtime.query(db, :extraction_base, key)
        {:ok, entry} = Memo.get(db, {:extraction_base, key})
        {:ok, extraction} = entry.value
        value = {:ok, %{extraction | base: nil}}
        now = Roux.Revision.advance(db.revision, :high)

        Memo.put(db, {:extraction_base, key}, %{
          entry
          | value: value,
            hash: :erlang.phash2(value),
            changed_at: now,
            verified_at: now
        })

        producers = [Argus.Extractors.ETS, Argus.Extractors.Purity]

        {:ok, fresh} =
          Argus.Pipeline.extract_module(beam, producers: producers, trace_imprecision: true)

        for producer <- producers do
          {:ok, actual} = Runtime.query(db, :extraction_producer, {module, producer})
          assert rows(actual) == rows(Map.fetch!(fresh.facts, producer))
        end
      after
        Session.close(session)
      end
    end)
  end

  test "prepared indexes survive interleaved modules and reaching-cache replacement", %{
    tmp_dir: dir
  } do
    peer = Peer.start!()

    Peer.run(peer, fn ->
      beams =
        Code.compile_string("""
        defmodule PreparedFixtureA do
          def run({:ok, table}, key), do: :ets.lookup(table, key)
          def run({:error, _reason}, _key), do: []
          def send_to(pid, value), do: send(pid, {:ok, value})
        end

        defmodule PreparedFixtureB do
          def run({:ok, table}, key), do: :ets.delete(table, key)
          def run({:error, _reason}, _key), do: :ok
          def send_to(pid, value), do: send(pid, {:error, value})
        end
        """)

      session =
        Session.open(
          modules: Argus.Graph.modules() ++ [Functions, Argus.Graph.Captures],
          blob: Path.join(dir, "store")
        )

      try do
        for {module, beam} <- beams do
          Input.set(session.db, :beam, module, %{data: beam, hash: Blob.digest(beam)})
        end

        [{first, first_beam}, {second, second_beam}] = Enum.sort(beams)
        producers = Extraction.extractors()

        {:ok, fresh} =
          Argus.Pipeline.extract_module(first_beam,
            producers: producers,
            trace_imprecision: true
          )

        for {producer, index} <- Enum.with_index(producers) do
          # Alternate tracked module queries with an external base restore.
          # The latter replaces Reaching's cache without touching the graph's
          # prepared-data cache, exercising a cache hit that must reinstall it.
          if rem(index, 2) == 0 do
            Runtime.query(session.db, :extraction_producer, {second, producer})
          else
            {:ok, data} = Argus.Pipeline.Disassemble.disassemble_path(second_beam)
            Argus.Pipeline.extract_data(data, producers: [:base], keep_base: true)
          end

          {:ok, actual} = Runtime.query(session.db, :extraction_producer, {first, producer})
          assert rows(actual) == rows(Map.fetch!(fresh.facts, producer))
        end
      after
        Session.close(session)
      end
    end)
  end

  defp rows(facts) do
    Map.new(facts, fn {relation, bytes} ->
      {relation, bytes |> Argus.Tsv.decode() |> MapSet.new()}
    end)
  end
end
