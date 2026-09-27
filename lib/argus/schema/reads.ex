defmodule Argus.Schema.Reads do
  @moduledoc """
  What a computation read of the schema (`Argus.Schema`) while it ran:
  the part of what it depends on that its code does not name.

  The schema's modules hold every relation as literals: keyed as code,
  any edit to any relation would move everything that reads one. A
  reader depends on the entries it reads — the pipeline decodes a few
  Layer-1 relations by their columns, and nothing else — so each
  accessor of the schema records the entry it returned, and a cache
  keys what was computed on what those entries are (the query graph's
  `schema_entry` edges, `Argus.Graph.Reads`).

  This module only records. It is code, not schema data: a change to it
  moves what every reader of the schema is keyed on, as any other code
  does (`Argus.Graph.Reads.schema_module?/1` leaves it in).

  ## Recording

  `track/1` runs a function with a set of reads of its own, in the
  process dictionary; every accessor records into the innermost set
  (`record/2`), in the callee, so a read is recorded however the
  accessor was reached. A set closed by `track/1` is added to the one
  around it: what a computation read, the computation that called it
  read too. `isolated/1` is the same without that last step, for a set
  that is one computation's own (a query's, whose readers depend on
  the query, not on what it read). A read outside any set records
  nothing — the only cost an in-process consumer of the schema pays is
  a dictionary lookup.

  A read is recorded by name (`t:read/0`), not by value: its value is
  read again by whoever keys on it, through the same accessor
  (`Argus.Schema.reread/1`). `Argus.Graph.Identity.SchemaReadsTest`
  calls every export of the schema's modules and fails unless each
  records a read whose value is exactly what it returned, and
  `Argus.Graph.Identity.SchemaPerturbationTest` runs every producer
  against a schema in which every entry it did not read is changed, and
  fails unless its rows are byte-identical.

  Only the process that tracks records: a computation that hands
  schema data to a process of its own tracks there too, and records
  what that process read here (`record_all/1`), as the pipeline does
  for its extraction workers.
  """

  @typedoc """
  A read of the schema: the accessor and the entry it named, as a
  string (`"columns bif_call"`, `"names"`), so that a manifest holding
  it is read back without making atoms.
  """
  @type read :: String.t()

  @key {__MODULE__, :reads}

  @doc """
  Records `read` in the innermost set this process tracks, if any, and
  returns `value`: the accessor's answer, which `read` names.
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
  Records each of `reads` (made in another process on this one's
  behalf) in the innermost set this process tracks, if any.
  """
  @spec record_all([read()]) :: :ok
  def record_all(reads) when is_list(reads) do
    case Process.get(@key) do
      nil -> :ok
      set -> Process.put(@key, Enum.reduce(reads, set, &Map.put(&2, &1, true)))
    end

    :ok
  end

  @doc """
  Runs `fun` and returns its result with the reads it recorded, sorted.
  The reads are added to an enclosing set as well, also when `fun`
  raises (and the raise goes on).
  """
  @spec track((-> result)) :: {result, [read()]} when result: term()
  def track(fun) when is_function(fun, 0), do: run(fun, :merge)

  @doc """
  Runs `fun` and returns its result with the reads it recorded, sorted,
  leaving an enclosing set as it was: the reads are `fun`'s own.
  """
  @spec isolated((-> result)) :: {result, [read()]} when result: term()
  def isolated(fun) when is_function(fun, 0), do: run(fun, :isolate)

  defp run(fun, how) do
    outer = Process.get(@key)
    Process.put(@key, %{})

    try do
      fun.()
    catch
      kind, reason ->
        close(outer, how)
        :erlang.raise(kind, reason, __STACKTRACE__)
    else
      result -> {result, close(outer, how)}
    end
  end

  defp close(outer, how) do
    reads = Process.get(@key, %{})

    case {outer, how} do
      {nil, _how} -> Process.delete(@key)
      {outer, :merge} -> Process.put(@key, Map.merge(outer, reads))
      {outer, :isolate} -> Process.put(@key, outer)
    end

    reads |> Map.keys() |> Enum.sort()
  end
end
