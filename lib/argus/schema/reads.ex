defmodule Argus.Schema.Reads do
  @moduledoc """
  Tracks the schema entries a computation reads so caches depend on those entries rather \
  than entire schema modules (`Argus.Graph.Reads`). This module is executable code; \
  changes to it invalidate schema readers normally.

  `track/1` records accessor names in a process-dictionary set and merges nested reads \
  into the enclosing set. `isolated/1` keeps its reads separate. Outside tracking, \
  `record/2` only checks the dictionary. Values are reread through \
  `Argus.Schema.reread/1` when computing cache keys.

  Tracking is process-local. Workers must track their own reads and send them to the \
  parent for `record_all/1`. Schema identity tests verify recorded values and confirm \
  that changing unread entries leaves producer output unchanged.
  """

  @typedoc """
  A schema accessor and entry name, such as `"columns bif_call"` or `"names"`. Stored as \
  a string so reading manifests creates no atoms.
  """
  @type read :: String.t()

  @key {__MODULE__, :reads}

  @doc """
  Records `read` in the innermost tracking set, if present, and returns `value` \
  unchanged.
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
  Adds reads collected by another process to this process's innermost tracking set, if \
  present.
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
  Runs `fun` and returns `{result, sorted_reads}`. Merges reads into any enclosing set, \
  even if `fun` raises; exceptions propagate.
  """
  @spec track((-> result)) :: {result, [read()]} when result: term()
  def track(fun) when is_function(fun, 0), do: run(fun, :merge)

  @doc """
  Runs `fun` and returns `{result, sorted_reads}` without changing any enclosing \
  tracking set.
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
