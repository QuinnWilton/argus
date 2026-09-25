defmodule Argus.Cache.Reads do
  @moduledoc """
  What a producer read of the schema (`Argus.Schema`) while it ran: what
  a store can key its rows on in place of the schema's code.

  The schema's modules hold every relation as literals: keyed as code
  (`Argus.Cache.Code`), any edit to any relation moves every producer's
  key. A producer depends on the entries it reads — the pipeline
  decodes a few Layer-1 relations by their columns, and nothing else —
  so each accessor of the schema records the entry it returned.

  ## Recording

  `track/1` runs a function with a set of reads of its own, in the
  process dictionary; every accessor records into the innermost set
  (`record/2`), in the callee, so a read is recorded however the
  accessor was reached. A set closed by `track/1` is added to the one
  around it: what a computation read, the computation that called it
  read too. A read outside any `track/1` records nothing — the only cost
  an in-process consumer of the schema pays is a dictionary lookup.

  A read is recorded by name (`t:read/0`), not by value: its value is
  read again when a store keys on it (`digest/1`), through the same
  accessor (`Argus.Schema.reread/1`). `Argus.SchemaReadsTest` calls
  every export of the schema's modules and fails unless each records a
  read whose value is exactly what it returned.

  Only the process that calls `track/1` records: a producer that handed
  schema data to a process of its own would need to track there too
  (none does).
  """

  @typedoc """
  A read of the schema: the accessor and the entry it named, as a
  string (`"columns bif_call"`, `"names"`), so that a manifest holding
  it is read back without making atoms.
  """
  @type read :: String.t()

  @key {__MODULE__, :reads}

  @doc """
  Records `read` in the set `track/1` keeps for this process, if any,
  and returns `value`: the accessor's answer, which `read` names.
  """
  @spec record(read(), value) :: value when value: term()
  def record(read, value) when is_binary(read) do
    case Process.get(@key) do
      nil -> value
      reads -> Process.put(@key, Map.put(reads, read, true))
    end

    value
  end

  @doc """
  Runs `fun` and returns its result with the reads it recorded, sorted.
  The reads are added to an enclosing `track/1`'s as well, also when
  `fun` raises (and the raise goes on).
  """
  @spec track((-> result)) :: {result, [read()]} when result: term()
  def track(fun) when is_function(fun, 0) do
    outer = Process.get(@key)
    Process.put(@key, %{})

    try do
      fun.()
    catch
      kind, reason ->
        close(outer)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result -> {result, close(outer)}
    end
  end

  defp close(outer) do
    reads = Process.get(@key, %{})

    case outer do
      nil -> Process.delete(@key)
      outer -> Process.put(@key, Map.merge(outer, reads))
    end

    reads |> Map.keys() |> Enum.sort()
  end

  @doc """
  The digest of what `read` names now (`Argus.Schema.reread/1`), as
  lowercase hex: what a key holds for it.
  """
  @spec digest(read()) :: String.t()
  def digest(read) when is_binary(read), do: read |> Argus.Schema.reread() |> value_digest()

  @doc """
  The digest of a value a read names: SHA-256 of its deterministic
  external term, as lowercase hex.
  """
  @spec value_digest(term()) :: String.t()
  def value_digest(value) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
