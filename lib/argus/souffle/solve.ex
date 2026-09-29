defmodule Argus.Souffle.Solve do
  @moduledoc """
  One Souffle solve through a `Roux.Blob` store: read back when it was
  kept, run in a scratch directory of its own when it was not, and
  kept by the content of its outputs.

  A solve is named by the caller's `key`: the program as a solve reads
  it (`Argus.Souffle.Program.declared_digest/2`), the solver, and what
  each input file holds. The action cache remembers each key's outputs
  (`Roux.Blob.remember/3`), as the digests of their files in the
  store's content-addressed entries, so a solve whose program and
  inputs have not moved is never run again, and nothing is written for
  it: no input is assembled, no directory made.

  A solve that misses works in a directory of its own
  (`Roux.Blob.scratch/2`, on the store's file system and removed as it
  returns, whatever happens):

    1. every input the program reads is placed there, as a hard link to
       its entry or written by the caller's `fill` function — an input
       with no rows is an empty file, never an absent one, which
       Souffle would refuse, or read as empty without a word;
    2. Souffle runs over it (`Argus.Souffle.execute_into/5`, bounded by
       `timeout:`);
    3. every output the program declares is moved into the store
       (`Roux.Blob.adopt/2`, a rename). A declared output the solver
       did not write is an `Argus.MissingRelationError`, never a
       relation without rows.

  Only a solve that succeeded is kept: a failure — the solver's error,
  its timeout, a missing output — is reported every time it happens.
  """

  alias Argus.Souffle
  alias Roux.Blob

  @typedoc """
  Where an input file's content comes from: an entry of the store, or
  a function writing it at the path it is given (`:ok` or an error,
  which fails the solve).
  """
  @type source :: {:cas, Blob.digest()} | {:fill, (Path.t() -> :ok | {:error, term()})}

  @typedoc "What a solve wrote: each output file's name and its entry's digest."
  @type outputs :: %{String.t() => Blob.digest()}

  @doc """
  The outputs of the solve `key` names, from the action cache or solved.

  `inputs` pairs each file the program reads (as the program names it,
  `Argus.Souffle.ram_io/2`) with its `t:source/0` — or is a function
  giving them, `{:ok, inputs}` or an error, called only when the solve
  is not kept; `outputs` names the files the program declares it
  writes.

  ## Options

    * `:bin` — the solver (required);
    * `:timeout` — milliseconds the solver may run (default
      `Argus.Souffle.default_timeout/0`).
  """
  @spec run(
          Blob.t(),
          term(),
          Path.t(),
          [{String.t(), source()}] | (-> {:ok, [{String.t(), source()}]} | {:error, term()}),
          [String.t()],
          keyword()
        ) :: {:ok, outputs()} | {:error, term()}
  def run(%Blob{} = store, key, rules_path, inputs, outputs, opts) do
    cache_key = {__MODULE__, key}

    case recall(store, cache_key) do
      {:ok, kept} ->
        {:ok, kept}

      :miss ->
        with {:ok, solved} <- solve(store, rules_path, inputs, outputs, opts) do
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

  defp solve(store, rules_path, inputs, outputs, opts) do
    bin = Keyword.fetch!(opts, :bin)
    timeout = Keyword.get(opts, :timeout, Souffle.default_timeout())

    Blob.scratch(store, fn dir ->
      facts = Path.join(dir, "facts")
      out = Path.join(dir, "out")

      with {:ok, inputs} <- given(inputs),
           :ok <- File.mkdir(facts),
           :ok <- File.mkdir(out),
           :ok <- place_inputs(store, inputs, facts),
           :ok <- Souffle.execute_into(bin, facts, Path.expand(rules_path), out, timeout) do
        adopt_outputs(store, outputs, out)
      end
    end)
  end

  defp given(inputs) when is_list(inputs), do: {:ok, inputs}
  defp given(inputs) when is_function(inputs, 0), do: inputs.()

  defp place_inputs(store, inputs, dir) do
    Enum.reduce_while(inputs, :ok, fn {file, source}, :ok ->
      case place(store, source, Path.join(dir, file)) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:input_failed, file, reason}}}
      end
    end)
  end

  defp place(store, {:cas, digest}, path), do: Blob.link(store, digest, path)
  defp place(_store, {:fill, fill}, path), do: fill.(path)

  # Every declared output, moved into the store; the first one the
  # solver did not write fails the solve.
  defp adopt_outputs(store, outputs, dir) do
    Enum.reduce_while(outputs, {:ok, %{}}, fn file, {:ok, acc} ->
      path = Path.join(dir, file)

      case Blob.adopt(store, path) do
        {:ok, digest} ->
          {:cont, {:ok, Map.put(acc, file, digest)}}

        {:error, :enoent} ->
          {:halt,
           {:error,
            %Argus.MissingRelationError{
              relation: Path.rootname(file),
              path: path,
              reason: :enoent
            }}}

        {:error, reason} ->
          {:halt, {:error, {:adopt_failed, file, reason}}}
      end
    end)
  end

  @doc """
  The rows of an output a solve kept, by its digest, sorted
  (`Argus.Souffle.decode_output/1`), or an `Argus.MissingRelationError`
  naming it when the store no longer holds it.
  """
  @spec rows(Blob.t(), String.t(), Blob.digest()) ::
          {:ok, [[String.t()]]} | {:error, Argus.MissingRelationError.t()}
  def rows(%Blob{} = store, file, digest) do
    case Blob.get(store, digest) do
      {:ok, content} ->
        {:ok, Argus.Souffle.decode_output(content)}

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
