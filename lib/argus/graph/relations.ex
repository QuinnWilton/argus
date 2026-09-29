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
    * `program_in_process(program)` — the same for the relations only
      the in-process passes read (`Argus.Schema.in_process_only/0`),
      over each module's `module_in_process`: demanded only by a
      program that reads one of them, a caller's own.
    * `relation({program, relation})` — one relation's digest, the grain
      a solve's inputs are named at: a relation an edit did not touch
      comes out equal here, and nothing that reads it runs. A layer-3
      relation (a prior, `Argus.Priors`) is the `priors` input's text;
      one no module has rows for is the empty relation.

  A relation's file is the concatenation of its modules' chunks, in the
  program's order, and never exists until a solve that is not kept
  needs it (`files/3`): then it is assembled in one pass over the
  segments of the program's modules that hold it, put into the blob
  store once, and remembered under its digest, so every later solve
  that needs the same relation links it.
  """

  use Roux.Query,
    code: [exclude: &Argus.Graph.Reads.schema_module?/1],
    around: {Argus.Graph.Reads, :around}

  alias Argus.Graph.Pack
  alias Roux.Blob
  alias Roux.Runtime

  @empty "empty"

  defquery :program_relations, key: program, returns: %{optional(atom()) => String.t()} do
    merkles(db, program, :module_semantic)
  end

  defquery :program_in_process, key: program, returns: %{optional(atom()) => String.t()} do
    db
    |> merkles(program, :module_in_process)
    |> Map.new(fn {relation, digest} -> {relation, "in-process:" <> digest} end)
  end

  # Each relation's Merkle digest over the modules' own, as `query` gives
  # them, in the program's order: one fan-out over its modules.
  defp merkles(db, program, query) do
    keys = Runtime.input(db, :program, program, default: [])

    db
    |> Runtime.parallel(Enum.map(keys, &{query, &1}), max_concurrency: System.schedulers_online())
    |> Enum.reduce(%{}, fn
      {:ok, found}, acc ->
        found
        |> module_digests(query)
        |> Enum.reduce(acc, fn {relation, digest}, acc ->
          Map.update(acc, relation, [digest], &[digest | &1])
        end)

      {:error, _}, acc ->
        acc
    end)
    |> Map.new(fn {relation, digests} -> {relation, merkle(Enum.reverse(digests))} end)
  end

  defp module_digests(relations, :module_semantic), do: relations
  defp module_digests(%{relations: relations}, :module_in_process), do: relations

  defquery :relation, key: {program, relation}, returns: String.t() do
    cond do
      prior?(relation) ->
        text = Runtime.input(db, :priors, {program, relation}, default: "")
        if text == "", do: @empty, else: "priors:" <> sha(text)

      in_process?(relation) ->
        db |> Runtime.query(:program_in_process, program) |> Map.get(relation, @empty)

      true ->
        db |> Runtime.query(:program_relations, program) |> Map.get(relation, @empty)
    end
  end

  defp in_process?(relation), do: relation in Argus.Schema.in_process_only()

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
  The digest of the program's `line_info`, which no relation digest
  covers (`module_semantic` leaves it out: a line that moves moves
  nothing a solve reads): a Merkle of its modules' chunk digests, as
  `relation/2`'s, for a facts directory made whole
  (`Argus.Run.extract_facts/3`). Reads the graph without edges.
  """
  @spec line_info(Roux.Database.t(), term()) :: String.t()
  def line_info(db, program) do
    keys = Runtime.untracked(fn -> Runtime.input(db, :program, program, default: []) end)

    digests =
      for key <- keys,
          {:ok, %{relations: %{line_info: digest}}} <-
            [Runtime.untracked(fn -> Runtime.query(db, :module_facts, key) end)],
          do: digest

    if digests == [], do: @empty, else: merkle(digests)
  end

  @doc """
  The blob store entries holding `relations`' files for `program`: each
  relation (with the digest `relation/2` gave it) to the digest of its
  file's content. Remembered by the relation's digest; the ones not
  remembered are assembled together, in one pass over the program's
  modules. Reads the graph without edges: called by a solve that
  already depends on each relation's digest.

  `producers` narrows every file to those producers' rows (`:all`, the
  default, for every producer's): a facts directory for some analyses
  (`Argus.Run.extract_facts/3`).
  """
  @spec files(Roux.Database.t(), term(), [{atom(), String.t()}], :all | [atom()]) ::
          {:ok, %{atom() => Blob.digest()}} | {:error, term()}
  def files(db, program, relations, producers \\ :all) do
    store = db.blob

    {known, missing} =
      Enum.reduce(relations, {%{}, []}, fn {relation, digest}, {known, missing} ->
        case remembered(store, digest, producers) do
          {:ok, file} -> {Map.put(known, relation, file), missing}
          :miss -> {known, [{relation, digest} | missing]}
        end
      end)

    with {:ok, made} <- assemble(db, program, Enum.reverse(missing), producers) do
      {:ok, Map.merge(known, made)}
    end
  end

  defp remembered(store, @empty, _producers) do
    {:ok, digest} = Blob.put(store, "")
    {:ok, digest}
  end

  defp remembered(store, digest, producers) do
    with {:ok, file} <- Blob.recall(store, remember_key(digest, producers)),
         true <- Blob.member?(store, file) do
      {:ok, file}
    else
      _ -> :miss
    end
  end

  defp remember_key(digest, :all), do: {__MODULE__, digest}
  defp remember_key(digest, producers), do: {__MODULE__, digest, Enum.sort(producers)}

  defp assemble(_db, _program, [], _producers), do: {:ok, %{}}

  defp assemble(db, program, missing, producers) do
    store = db.blob
    {priors, facts} = Enum.split_with(missing, fn {_r, digest} -> prior_digest?(digest) end)

    {in_process, facts} =
      Enum.split_with(facts, fn {_r, digest} -> in_process_digest?(digest) end)

    with {:ok, from_priors} <- priors_files(db, program, priors),
         {:ok, from_facts} <- facts_files(db, program, facts, producers, :module_facts),
         {:ok, from_in_process} <-
           facts_files(db, program, in_process, producers, :module_in_process) do
      made = from_priors |> Map.merge(from_facts) |> Map.merge(from_in_process)

      for {relation, digest} <- missing,
          do:
            _ =
              Blob.remember(store, remember_key(digest, producers), Map.fetch!(made, relation))

      {:ok, made}
    end
  end

  defp prior_digest?("priors:" <> _), do: true
  defp prior_digest?(_digest), do: false

  defp in_process_digest?("in-process:" <> _), do: true
  defp in_process_digest?(_digest), do: false

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

  defp facts_files(_db, _program, [], _producers, _query), do: {:ok, %{}}

  # One pass over the program's modules: each module's segments that hold
  # a missing relation are read once (`Argus.Graph.Pack.read_chunks/6`,
  # which extracts a module again whose segment the store lost), and its
  # chunk of every missing relation appended to that relation's file,
  # written in a scratch directory on the store's file system and moved
  # into it.
  defp facts_files(db, program, facts, producers, query) do
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

      written =
        try do
          Enum.reduce_while(keys, :ok, fn key, :ok ->
            case Runtime.untracked(fn -> Runtime.query(db, query, key) end) do
              {:ok, %{pack: pack, relations: chunks}} ->
                if Enum.any?(Map.keys(chunks), &MapSet.member?(wanted, &1)),
                  do: append(db, {query, key}, pack, {relations, producers}, devices),
                  else: {:cont, :ok}

              {:error, _} ->
                {:cont, :ok}
            end
          end)
        after
          Enum.each(devices, fn {_relation, {_path, device}} -> File.close(device) end)
        end

      with :ok <- written do
        Enum.reduce_while(devices, {:ok, %{}}, fn {relation, {path, _device}}, {:ok, acc} ->
          case Blob.adopt(store, path) do
            {:ok, file} -> {:cont, {:ok, Map.put(acc, relation, file)}}
            {:error, reason} -> {:halt, {:error, {:relation_write_failed, relation, reason}}}
          end
        end)
      end
    end)
  end

  # One module's chunk of each relation, appended to the relation's file.
  defp append(db, {query, key}, pack, {relations, producers}, devices) do
    case Pack.read_chunks(db, query, key, pack, relations, producers) do
      {:ok, chunks} ->
        for relation <- relations, bytes = Map.get(chunks, relation, ""), bytes != "" do
          {_path, device} = Map.fetch!(devices, relation)
          :ok = IO.binwrite(device, bytes)
        end

        {:cont, :ok}

      {:error, _} = error ->
        {:halt, error}
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
