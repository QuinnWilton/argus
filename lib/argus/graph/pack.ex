defmodule Argus.Graph.Pack do
  @moduledoc """
  A module's facts as the query graph keeps them: text, one segment per
  producer in the blob store (`Roux.Blob`). `Argus.Graph.FunctionPack`
  extracts them, function by function, and `Argus.Graph.ModuleTrace`
  finds a module's pack again.

  ## Segments and packs

  A module's rows from one producer (`Argus.Pipeline`'s `:base` and each
  extractor) are that producer's *segment*: for each relation it has
  rows for, the bytes of its lines as a `.facts` file holds them
  (`Argus.Pipeline.Writer.encode/2`), in one blob. A producer with no
  rows for the module has none. The module's *pack* is their index:
  each producer that has a segment, in producer order, with the
  segment's digest and the relations it holds. A relation's chunk of the
  module is its producers' bytes joined in that order (`chunks/4`), and a
  relation's file is its modules' chunks joined (`Argus.Graph.Relations`).

  Each relation of the module is named by a digest of its chunk: the
  SHA-256 of its bytes when one producer has rows for it, as all but a
  few relations have, else of its producers' digests, in producer
  order. So a producer that runs again writes its own segment alone,
  and the module's digests are made without reading any other.

  ## A blob the store lost

  A kept entry trusts the blobs its value names without a look: a warm
  run reads no segment it does not assemble a relation from. One may
  still be gone (collected while a run used it, or removed by hand).
  Reading a module's chunks through the graph (`read_chunks/6`) then
  extracts the module again, as a cold run does, and puts the blobs back
  under the digests the pack names — the same beam under the same code
  makes the same bytes — so the run goes on and every later one finds
  them (`restore/2`).
  """

  alias Argus.Pipeline
  alias Roux.Blob
  alias Roux.Runtime

  # A relation more than one producer has rows for is named by its
  # producers' digests, under a prefix no single chunk's digest is
  # taken over.
  @joined "argus-joined-chunk\n"

  @typedoc """
  A module's facts: its name, its pack's digest, each relation's chunk
  digest, and whether it was lost.
  """
  @type t :: %{
          module: module() | nil,
          pack: Blob.digest(),
          relations: %{atom() => binary()},
          lost: boolean()
        }

  @typedoc """
  A pack: each producer with a segment, in producer order, with its
  segment's digest and the relations the segment holds.
  """
  @type pack :: [{Pipeline.producer(), Blob.digest(), [atom()]}]

  @typedoc """
  Which of a module's relations a pack holds: `:extracted`, every one
  but the relations only the in-process passes read
  (`Argus.Schema.in_process_only/0`), from every producer; or
  `:in_process`, those alone, from the base (what a program of the
  caller's own that reads them solves over).
  """
  @type kind :: :extracted | :in_process

  @doc """
  A module's facts from each producer's encoded rows
  (`Argus.Pipeline.Writer.encode/2`), in producer order: each segment
  and the pack put into the store, and the blobs the value names, for
  the query that makes it to hold.
  """
  @spec from_segments(Blob.t(), module() | nil, [{Pipeline.producer(), map()}]) ::
          {t(), [Blob.digest()]}
  def from_segments(store, module, segments) do
    chosen = for {producer, encoded} <- segments, do: {producer, segment(store, encoded)}

    index =
      for {producer, %{segment: segment, relations: relations}} <- chosen,
          segment != nil,
          do: {producer, segment, relations |> Map.keys() |> Enum.sort()}

    {:ok, pack} = Blob.put_term(store, index)
    held = [pack | for({_, %{segment: segment}} <- chosen, segment != nil, do: segment)]

    {%{module: module, pack: pack, relations: relation_digests(chosen), lost: false}, held}
  end

  # A producer's rows: the segment holding them (none for no rows), and
  # each relation's digest.
  defp segment(store, encoded) do
    relations = Map.new(encoded, fn {relation, bytes} -> {relation, sha256(bytes)} end)

    case map_size(encoded) do
      0 ->
        %{segment: nil, relations: relations}

      _ ->
        {:ok, segment} = Blob.put_term(store, encoded)
        %{segment: segment, relations: relations}
    end
  end

  # Each relation's digest: its one producer's, or its producers'
  # joined, in producer order.
  defp relation_digests(chosen) do
    chosen
    |> Enum.flat_map(fn {_producer, %{relations: relations}} -> Enum.to_list(relations) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {relation, [digest]} -> {relation, digest}
      {relation, digests} -> {relation, sha256([@joined | digests])}
    end)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data)

  @doc """
  The chunks of `relations` in the module whose pack is `pack`: each
  relation's bytes from `producers` (`:all`, the default, for every
  producer's), joined in producer order; a relation the module has no
  rows for from them is left out. Reads the pack and the segments that
  hold one of the relations, each once. `{:missing, digest}` names a
  blob the store no longer has.
  """
  @spec chunks(Blob.t(), Blob.digest(), [atom()], :all | [Pipeline.producer()]) ::
          {:ok, %{atom() => binary()}} | {:missing, Blob.digest()}
  def chunks(store, pack, relations, producers \\ :all) do
    wanted = MapSet.new(relations)

    with {:ok, index} <- get_term(store, pack) do
      index
      |> Enum.filter(fn {producer, _segment, held} ->
        (producers == :all or producer in producers) and
          Enum.any?(held, &MapSet.member?(wanted, &1))
      end)
      |> Enum.reduce_while({:ok, %{}}, fn {_producer, segment, _held}, {:ok, acc} ->
        case get_term(store, segment) do
          {:ok, rows} ->
            acc =
              rows
              |> Map.take(relations)
              |> Enum.reduce(acc, fn {relation, bytes}, acc ->
                Map.update(acc, relation, [bytes], &[bytes | &1])
              end)

            {:cont, {:ok, acc}}

          missing ->
            {:halt, missing}
        end
      end)
      |> case do
        {:ok, acc} ->
          {:ok,
           Map.new(acc, fn {r, parts} -> {r, parts |> Enum.reverse() |> IO.iodata_to_binary()} end)}

        missing ->
          missing
      end
    end
  end

  @doc """
  `chunks/4` of the module `beam_key`, whose facts `query` keeps
  (`:module_facts` or `:module_in_process`) under `pack`, read from
  `db`'s store: when the store no longer has a blob the pack names (a
  segment collected while a trace still named it), the module is
  extracted again (`restore/3`) and the chunks read from what that puts
  back. `{:error, {:facts_lost, beam_key, digest, reason}}` when they
  cannot be.

  Reads the graph without edges: the caller depends on `query`'s entry
  already, and that entry on what made the pack.
  """
  @spec read_chunks(
          Roux.Database.t(),
          :module_facts | :module_in_process,
          term(),
          Blob.digest(),
          [atom()],
          :all | [Pipeline.producer()]
        ) :: {:ok, %{atom() => binary()}} | {:error, term()}
  def read_chunks(db, query, beam_key, pack, relations, producers \\ :all) do
    with {:missing, digest} <- chunks(db.blob, pack, relations, producers) do
      restored =
        with :ok <- restore(db, {query, beam_key}, pack),
             {:missing, digest} <- chunks(db.blob, pack, relations, producers) do
          {:error, {:blob_missing, digest}}
        end

      case restored do
        {:ok, chunks} -> {:ok, chunks}
        {:error, reason} -> {:error, {:facts_lost, beam_key, digest, reason}}
      end
    end
  end

  @doc """
  Puts back the blobs of `pack` the store lost, by extracting the module
  `beam_key` again: every producer `query` keeps rows of, as a cold run
  does, each segment put again and the pack with them. The same beam
  under the same code makes the same bytes (extraction is
  deterministic), so they come back under the digests `pack` names:
  `:ok`; `{:error, {:not_reproduced, made}}` when the extraction made
  another pack, or the extraction's error.

  Emits `[:argus, :graph, :pack]` when rebuilding a function pack. Reads the
  graph without edges and records no read of the schema: the entry
  whose value names `pack` depends on what made it already.
  """
  @spec restore(
          Roux.Database.t(),
          {:module_facts | :module_in_process, term()},
          Blob.digest()
        ) :: :ok | {:error, term()}
  def restore(db, {query, beam_key}, pack) do
    {result, _reads} =
      Argus.Schema.Reads.isolated(fn ->
        Runtime.untracked(fn ->
          case Runtime.query(db, :module_beam, beam_key) do
            {:ok, _beam} -> restore(db, query, beam_key, pack)
            :external -> {:error, {:external, beam_key}}
          end
        end)
      end)

    result
  end

  defp restore(db, query, beam_key, pack) do
    kind = if query == :module_facts, do: :extracted, else: :in_process

    case Argus.Graph.FunctionPack.repair(db, beam_key, kind) do
      {:ok, %{pack: ^pack}, _held} -> :ok
      {:ok, %{pack: made}, _held} -> {:error, {:not_reproduced, made}}
      error -> error
    end
  end

  defp get_term(store, digest) do
    case Blob.get_term(store, digest) do
      {:ok, term} -> {:ok, term}
      :miss -> {:missing, digest}
    end
  end
end
