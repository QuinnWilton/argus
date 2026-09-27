defmodule Argus.Graph.Relations do
  @moduledoc """
  A program's relations: named by digests, made into files only when a
  solve needs one.

    * `program_relations(program)` — each relation any of the program's
      modules has rows for, and a Merkle digest of it: of its modules'
      chunk digests (`module_semantic`, without `line_info`), in the
      program's order. The modules' facts are brought up to date as one
      fan-out (`Roux.Runtime.parallel/3`), extracted side by side on a
      cold run and validated side by side on a warm one.
    * `relation({program, relation})` — one relation's digest, the grain
      a solve's inputs are named at: a relation an edit did not touch
      comes out equal here, and nothing that reads it runs. A layer-3
      relation (a prior, `Argus.Priors`) is the `priors` input's text;
      one no module has rows for is the empty relation.

  A relation's file is the concatenation of its modules' chunks, in the
  program's order, and never exists until a solve that is not kept
  needs it (`files/3`): then it is assembled in one pass over the
  program's combined packs, put into the blob store once, and
  remembered under its digest, so every later solve that needs the same
  relation links it.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Graph.Pack
  alias Roux.Blob
  alias Roux.Runtime

  @empty "empty"

  defquery :program_relations, key: program, returns: %{optional(atom()) => String.t()} do
    keys = Runtime.input(db, :program, program, default: [])

    semantic =
      Runtime.parallel(db, Enum.map(keys, &{:module_semantic, &1}),
        max_concurrency: System.schedulers_online()
      )

    semantic
    |> Enum.reduce(%{}, fn
      {:ok, relations}, acc ->
        Enum.reduce(relations, acc, fn {relation, digest}, acc ->
          Map.update(acc, relation, [digest], &[digest | &1])
        end)

      {:error, _}, acc ->
        acc
    end)
    |> Map.new(fn {relation, digests} -> {relation, merkle(Enum.reverse(digests))} end)
  end

  defquery :relation, key: {program, relation}, returns: String.t() do
    if prior?(relation) do
      text = Runtime.input(db, :priors, {program, relation}, default: "")
      if text == "", do: @empty, else: "priors:" <> sha(text)
    else
      db |> Runtime.query(:program_relations, program) |> Map.get(relation, @empty)
    end
  end

  # Whether `relation` is a prior, reading that relation's entry alone:
  # the whole of layer 3 moves with any prior's prose.
  defp prior?(relation), do: match?({:ok, %{layer: 3}}, Argus.Schema.fetch(relation))

  defp merkle(digests) do
    digests
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    |> then(&("modules:#{length(digests)}:" <> &1))
  end

  defp sha(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)

  @doc """
  The blob store entries holding `relations`' files for `program`: each
  relation (with the digest `relation/2` gave it) to the digest of its
  file's content. Remembered by the relation's digest; the ones not
  remembered are assembled together, in one pass over the program's
  modules. Reads the graph without edges: called by a solve that
  already depends on each relation's digest.
  """
  @spec files(Roux.Database.t(), term(), [{atom(), String.t()}]) ::
          {:ok, %{atom() => Blob.digest()}} | {:error, term()}
  def files(db, program, relations) do
    store = db.blob

    {known, missing} =
      Enum.reduce(relations, {%{}, []}, fn {relation, digest}, {known, missing} ->
        case remembered(store, digest) do
          {:ok, file} -> {Map.put(known, relation, file), missing}
          :miss -> {known, [{relation, digest} | missing]}
        end
      end)

    with {:ok, made} <- assemble(db, program, Enum.reverse(missing)) do
      {:ok, Map.merge(known, made)}
    end
  end

  defp remembered(store, @empty) do
    {:ok, digest} = Blob.put(store, "")
    {:ok, digest}
  end

  defp remembered(store, digest) do
    with {:ok, file} <- Blob.recall(store, {__MODULE__, digest}),
         true <- Blob.member?(store, file) do
      {:ok, file}
    else
      _ -> :miss
    end
  end

  defp assemble(_db, _program, []), do: {:ok, %{}}

  defp assemble(db, program, missing) do
    store = db.blob
    {priors, facts} = Enum.split_with(missing, fn {_r, digest} -> prior_digest?(digest) end)

    with {:ok, from_priors} <- priors_files(db, program, priors),
         {:ok, from_facts} <- facts_files(db, program, facts) do
      made = Map.merge(from_priors, from_facts)

      for {relation, digest} <- missing,
          do: _ = Blob.remember(store, {__MODULE__, digest}, Map.fetch!(made, relation))

      {:ok, made}
    end
  end

  defp prior_digest?("priors:" <> _), do: true
  defp prior_digest?(_digest), do: false

  defp priors_files(db, program, priors) do
    Enum.reduce_while(priors, {:ok, %{}}, fn {relation, _digest}, {:ok, acc} ->
      text =
        Runtime.untracked(fn -> Runtime.input(db, :priors, {program, relation}, default: "") end)

      case Blob.put(db.blob, text) do
        {:ok, file} -> {:cont, {:ok, Map.put(acc, relation, file)}}
        {:error, reason} -> {:halt, {:error, {:relation_write_failed, relation, reason}}}
      end
    end)
  end

  defp facts_files(_db, _program, []), do: {:ok, %{}}

  # One pass over the program's modules: each module's combined pack is
  # read once, and its chunk of every missing relation appended to that
  # relation's file, written in a scratch directory on the store's file
  # system and moved into it.
  defp facts_files(db, program, facts) do
    store = db.blob
    relations = Enum.map(facts, &elem(&1, 0))
    wanted = MapSet.new(relations)

    keys = Runtime.untracked(fn -> Runtime.input(db, :program, program, default: []) end)

    Blob.scratch(store, fn dir ->
      devices =
        Map.new(relations, fn relation ->
          path = Path.join(dir, Atom.to_string(relation))

          {:ok, device} =
            File.open(path, [:write, :raw, :binary, {:delayed_write, 1_048_576, 2_000}])

          {relation, {path, device}}
        end)

      try do
        Enum.each(keys, fn key ->
          case Runtime.untracked(fn -> Runtime.query(db, :module_facts, key) end) do
            {:ok, %{pack: pack, relations: chunks}} ->
              if Enum.any?(Map.keys(chunks), &MapSet.member?(wanted, &1)) do
                {:ok, contents} = read_pack!(store, pack)

                for relation <- relations, bytes = Pack.chunk(contents, relation), bytes != "" do
                  {_path, device} = Map.fetch!(devices, relation)
                  :ok = IO.binwrite(device, bytes)
                end
              end

            {:error, _} ->
              :ok
          end
        end)
      after
        Enum.each(devices, fn {_relation, {_path, device}} -> File.close(device) end)
      end

      Enum.reduce_while(devices, {:ok, %{}}, fn {relation, {path, _device}}, {:ok, acc} ->
        case Blob.adopt(store, path) do
          {:ok, file} -> {:cont, {:ok, Map.put(acc, relation, file)}}
          {:error, reason} -> {:halt, {:error, {:relation_write_failed, relation, reason}}}
        end
      end)
    end)
  end

  defp read_pack!(store, pack) do
    case Pack.read(store, pack) do
      {:ok, contents} -> {:ok, contents}
      :miss -> raise Roux.Blob.MissingError, store: store.root, digest: pack
    end
  end

  @doc """
  One relation of `program` as rows (`Argus.Tsv.decode/1`), through the
  graph: what a caller outside it reads a relation as (the priors'
  questions, a test). Depends on the relation's digest when called in a
  query.
  """
  @spec rows(Roux.Database.t(), term(), atom()) :: [[String.t()]]
  def rows(db, program, relation) do
    digest = relation(db, {program, relation})
    {:ok, %{^relation => file}} = files(db, program, [{relation, digest}])
    {:ok, content} = Blob.get(db.blob, file)
    Argus.Tsv.decode(content)
  end
end
