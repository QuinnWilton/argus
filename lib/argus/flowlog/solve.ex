defmodule Argus.FlowLog.Solve do
  @moduledoc """
  One solve through a `Roux.Blob` store: read back when it was kept,
  else committed to the engine kept for its lineage, and kept by the
  content of its outputs.

  A solve is named by the caller's `key`: the program's digest and each
  input's identity. The action cache remembers each key's outputs
  (`Roux.Blob.remember/3`) as the digests of their files in the store,
  so a solve whose program and inputs have not moved is never run again,
  in this VM or another, and nothing is read or written for it.

  A solve that misses goes to an engine (`Argus.FlowLog.Pool`), the one
  kept for the solve's lineage (a project and a program) and owner (the
  database solving, whose exit stops it), or a new one:

    1. the engine is told only the inputs whose identity differs from
       what it holds, each by the store's file for it (or one the
       caller's `fill` function writes) and the file of what it holds,
       placed again from the source it was committed from, and diffs
       the two itself; a new engine is told every input. An engine
       keeps no copy of its inputs' files: a held input whose file the
       store has since collected is told to a new engine instead;
    2. the engine applies the difference as one epoch of its dataflow,
       bounded by `:timeout`, and writes each output it changed, whole
       and sorted, into a scratch directory of the store's;
    3. each written output is moved into the store (`Roux.Blob.adopt/2`);
       an output the commit did not change keeps the digest it had.

  The engine's previous outputs are the solve's unless the commit moved
  them, so the outputs a lineage's engine reports must still be in the
  store: one collected since is asked of the engine again (`"rewrite"`).
  A declared output the engine did not write is an
  `Argus.MissingRelationError`, never a relation without rows.

  Only a solve that succeeded is kept: a failure (the engine's error, its
  timeout, its exit) is reported every time it happens, and stops the
  engine, whose state is then unknown; the next solve starts another.
  """

  alias Argus.FlowLog.Engine
  alias Argus.FlowLog.Pool
  alias Roux.Blob

  @typedoc """
  Where an input file's content comes from: an entry of the store, or
  a function writing it at the path it is given.
  """
  @type source :: {:cas, Blob.digest()} | {:fill, (Path.t() -> :ok | {:error, term()})}

  @typedoc "What a solve wrote: each output file's name and its entry's digest."
  @type outputs :: %{String.t() => Blob.digest()}

  @typedoc """
  What a solve needs of its engine:

    * `:lineage` — what the engine is kept by (a project, a program);
    * `:owner` — the process whose exit stops the engine (the solving
      database's);
    * `:start` — `Argus.FlowLog.Engine.start_link/1`'s options, the
      engine already built; `workers: :auto` (or none) chooses its
      workers by the size of the inputs (`Argus.FlowLog.workers/2`).
  """
  @type engine_spec :: %{lineage: term(), owner: pid(), start: keyword()}

  @doc """
  The outputs of the solve `key` names, from the action cache or solved.

  `inputs` pairs each input relation (by name) with its `t:source/0`
  and the identity its content goes by — or is a function giving them,
  `{:ok, inputs}` or an error, called only when the solve is not kept;
  `outputs` names the files the program declares it writes.

  `engine` is a function returning the `t:engine_spec/0` (or an error),
  called only when the solve is not kept: building an engine is no part
  of a warm run.

  ## Options

    * `:timeout` — milliseconds a commit may run (default
      `Argus.FlowLog.default_timeout/0`).
  """
  @spec run(
          Blob.t(),
          term(),
          [{String.t(), source(), term()}]
          | (-> {:ok, [{String.t(), source(), term()}]} | {:error, term()}),
          [String.t()],
          (-> {:ok, engine_spec()} | {:error, term()}),
          keyword()
        ) :: {:ok, outputs()} | {:error, term()}
  def run(%Blob{} = store, key, inputs, outputs, engine, opts) do
    cache_key = {__MODULE__, key}

    case recall(store, cache_key) do
      {:ok, kept} ->
        {:ok, kept}

      :miss ->
        with {:ok, spec} <- engine.(),
             {:ok, inputs} <- given(inputs),
             {:ok, solved} <- solve(store, spec, inputs, outputs, opts) do
          _ = Blob.remember(store, cache_key, solved)
          {:ok, solved}
        end
    end
  end

  # A remembered solve whose every output is still in the store; one
  # that lost an entry to a collection is solved again.
  defp recall(store, cache_key) do
    with {:ok, kept} when is_map(kept) <- Blob.recall(store, cache_key),
         true <- Enum.all?(kept, fn {_file, digest} -> Blob.member?(store, digest) end) do
      {:ok, kept}
    else
      _ -> :miss
    end
  end

  defp given(inputs) when is_list(inputs), do: {:ok, inputs}
  defp given(inputs) when is_function(inputs, 0), do: inputs.()

  defp solve(store, %{lineage: lineage, owner: owner, start: start}, inputs, outputs, opts) do
    timeout = Keyword.get(opts, :timeout, Argus.FlowLog.default_timeout())
    pool_key = {owner, store.root, lineage, Keyword.fetch!(start, :digest)}

    # An engine started here takes its workers by the size of what it is
    # first committed (`Argus.FlowLog.workers/2`), and keeps them.
    started = fn ->
      workers =
        Argus.FlowLog.workers(Keyword.get(start, :workers, :auto), input_bytes(store, inputs))

      {:ok, Keyword.put(start, :workers, workers)}
    end

    # What the engine holds, the commit, and the outputs it leaves are
    # one step: two solves of a lineage take turns, and each tells the
    # engine every input that differs from what the other left. A
    # commit that fails (midway, by its timeout, by a crash) leaves the
    # engine's state unknown, and the pool stops it: the next solve
    # starts afresh.
    once = fn ->
      :global.trans(
        {{__MODULE__, pool_key}, self()},
        fn ->
          Pool.with_engine(pool_key, owner, started, fn engine ->
            Blob.scratch(store, fn dir -> commit(store, engine, dir, inputs, outputs, timeout) end)
          end)
        end,
        [node()],
        :infinity
      )
    end

    # A held input whose file the store has lost cannot be diffed: the
    # failed commit stopped the engine, and a new one is told every input.
    case once.() do
      {:error, {:flowlog_previous_missing, _relation}} -> once.()
      result -> result
    end
  end

  defp commit(store, engine, dir, inputs, outputs, timeout) do
    fills = Path.join(dir, "inputs")
    out = Path.join(dir, "out")
    File.mkdir_p!(fills)
    File.mkdir_p!(out)

    with {:ok, {held, previous}} <- Engine.snapshot(engine),
         rewrite =
           previous != %{} and not Enum.all?(previous, fn {_f, d} -> Blob.member?(store, d) end),
         changed =
           for(
             {name, source, identity} <- inputs,
             held_identity(held, name) != identity,
             do: {name, source, identity}
           ),
         {:ok, paths} <- place_all(store, changed, fills),
         {:ok, prior} <- place_held(store, changed, held, Path.join(dir, "held")),
         entries =
           Map.new(paths, fn {name, path} ->
             {name, if(prior[name], do: {path, prior[name]}, else: path)}
           end),
         # What the engine holds of each input: its identity, and the
         # source of the file it was committed from, to diff the next one.
         identities =
           Map.new(changed, fn {name, source, identity} -> {name, {identity, source}} end),
         {:ok, _report} <-
           Engine.commit(engine, out, entries, identities, timeout, rewrite: rewrite),
         {:ok, solved} <- adopt_outputs(store, outputs, out, if(rewrite, do: %{}, else: previous)) do
      :ok = Engine.put_outputs(engine, solved)
      {:ok, solved}
    end
  end

  defp input_bytes(store, inputs) do
    inputs
    |> Enum.map(fn
      {_name, {:cas, digest}, _identity} ->
        case File.stat(Blob.path(store, digest)) do
          {:ok, %File.Stat{size: size}} -> size
          {:error, _} -> 0
        end

      {_name, {:fill, _fill}, _identity} ->
        0
    end)
    |> Enum.sum()
  end

  defp held_identity(held, name) do
    case Map.fetch(held, name) do
      {:ok, {identity, _source}} -> identity
      :error -> :none
    end
  end

  # The file of what the engine holds of each changed input it holds,
  # placed again from its source.
  defp place_held(store, changed, held, dir) do
    File.mkdir_p!(dir)

    Enum.reduce_while(changed, {:ok, %{}}, fn {name, _source, _identity}, {:ok, acc} ->
      case Map.fetch(held, name) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, {_identity, source}} ->
          case place(store, source, Path.join(dir, name)) do
            {:ok, path} -> {:cont, {:ok, Map.put(acc, name, path)}}
            {:error, {:missing_entry, _}} -> {:halt, {:error, {:flowlog_previous_missing, name}}}
            {:error, reason} -> {:halt, {:error, {:input_failed, name, reason}}}
          end
      end
    end)
  end

  defp place_all(store, inputs, dir) do
    Enum.reduce_while(inputs, {:ok, %{}}, fn {name, source, _identity}, {:ok, acc} ->
      case place(store, source, Path.join(dir, name)) do
        {:ok, path} -> {:cont, {:ok, Map.put(acc, name, path)}}
        {:error, reason} -> {:halt, {:error, {:input_failed, name, reason}}}
      end
    end)
  end

  # The store's entry is read where it lies: the engine only reads it.
  defp place(store, {:cas, digest}, _path) do
    if Blob.member?(store, digest),
      do: {:ok, Blob.path(store, digest)},
      else: {:error, {:missing_entry, digest}}
  end

  defp place(_store, {:fill, fill}, path) do
    case fill.(path) do
      :ok -> {:ok, path}
      {:error, _} = error -> error
    end
  end

  # Every declared output: written by this commit and moved into the
  # store, or unchanged and kept by the digest it had.
  defp adopt_outputs(store, outputs, dir, previous) do
    Enum.reduce_while(outputs, {:ok, %{}}, fn file, {:ok, acc} ->
      path = Path.join(dir, file)

      cond do
        File.regular?(path) ->
          case Blob.adopt(store, path) do
            {:ok, digest} -> {:cont, {:ok, Map.put(acc, file, digest)}}
            {:error, reason} -> {:halt, {:error, {:adopt_failed, file, reason}}}
          end

        Map.has_key?(previous, file) ->
          {:cont, {:ok, Map.put(acc, file, Map.fetch!(previous, file))}}

        true ->
          {:halt,
           {:error,
            %Argus.MissingRelationError{
              relation: Path.rootname(file),
              path: path,
              reason: :enoent
            }}}
      end
    end)
  end

  @doc """
  The rows of an output a solve kept, by its digest, sorted
  (`Argus.FlowLog.decode_output/1`), or an `Argus.MissingRelationError`
  naming it when the store no longer holds it.
  """
  @spec rows(Blob.t(), String.t(), Blob.digest()) ::
          {:ok, [[String.t()]]} | {:error, Argus.MissingRelationError.t()}
  def rows(%Blob{} = store, file, digest) do
    case Blob.get(store, digest) do
      {:ok, content} ->
        {:ok, Argus.FlowLog.decode_output(content)}

      :miss ->
        {:error,
         %Argus.MissingRelationError{
           relation: Path.rootname(file),
           path: Blob.path(store, digest),
           reason: :enoent
         }}
    end
  end
end
