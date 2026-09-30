defmodule Argus.Graph.Prepared do
  @moduledoc false

  alias Argus.Instr.Reaching
  alias Argus.Pipeline
  alias Argus.Pipeline.Base
  alias Roux.Database

  @cache {__MODULE__, :cache}

  @type captured :: {binary(), {map(), Reaching.prepared() | nil}} | nil

  @doc "Captures a pipeline's live base without adding it to the query result."
  @spec capture(((binary(), map() -> :ok) -> result)) :: {result, captured()}
        when result: term()
  def capture(run) do
    key = {__MODULE__, make_ref()}

    remember = fn kept, data ->
      Process.put(key, {kept, snapshot(Map.put_new(data, :beam, ""))})
      :ok
    end

    try do
      result = run.(remember)
      {result, Process.get(key)}
    after
      Process.delete(key)
    end
  end

  @doc "Retains a successful cold base under its already computed fingerprint."
  @spec remember(Database.t(), term(), term(), map(), captured()) :: :ok
  def remember(db, module, key, %{base: kept, fingerprint: identity}, {kept, prepared})
      when is_binary(kept) do
    put(db, module, key, identity, prepared)
    :ok
  end

  def remember(_db, _module, _key, _base, _captured), do: :ok

  @doc "Restores one function only when its live prepared state is unavailable."
  @spec function(Database.t(), term(), term(), map()) :: map()
  def function(db, module, key, %{base: kept, fingerprint: identity}) do
    fetch(db, module, key, identity, fn ->
      restored = Base.restore(kept, "")
      {:ok, typed} = restored.typed

      Map.merge(restored.data, %{
        typed: typed,
        cfg: restored.cfg,
        reaching: restored.reaching
      })
    end)
  end

  @doc "Reuses prepared indexes and reinstalls reaching solutions when necessary."
  @spec fetch(Database.t(), term(), term(), term(), (-> map())) :: map()
  def fetch(db, module, key, identity, prepare) do
    {data, solutions} =
      case Map.get(entries(db, module), key) do
        {^identity, data, solutions} -> {data, solutions}
        _ -> put(db, module, key, identity, snapshot(prepare.()))
      end

    if solutions, do: Reaching.restore_prepared(solutions)
    data
  end

  defp snapshot(data) do
    data = Pipeline.prepare_indexes(data)
    solutions = if data.reaching, do: Reaching.prepare(data.functions)
    {data, solutions}
  end

  defp put(db, module, key, identity, {data, solutions}) do
    entries = Map.put(entries(db, module), key, {identity, data, solutions})
    Process.put(@cache, {scope(db, module), entries})
    {data, solutions}
  end

  # Only the worker's current database/module/code version retains live data.
  # A query value holds its serializable base and fingerprint instead.
  defp entries(db, module) do
    scope = scope(db, module)

    case Process.get(@cache) do
      {^scope, entries} -> entries
      _ -> %{}
    end
  end

  defp scope(db, module),
    do: {Database.id(db), module, Database.code_version(db, :extraction_local)}

  @doc "Assembles a module from live function bases and their existing indexes."
  @spec assemble(map(), [map()]) :: map()
  def assemble(metadata, parts) do
    reaching =
      if Enum.all?(parts, & &1.reaching),
        do: Enum.reduce(parts, MapSet.new(), &MapSet.union(&2, &1.reaching))

    Map.merge(metadata, %{
      functions: Enum.flat_map(parts, & &1.functions),
      line_table: Enum.reduce(parts, %{}, &Map.merge(&2, &1.line_table)),
      cfg: Enum.reduce(parts, %{}, &Map.merge(&2, &1.cfg)),
      typed: merge_typed(parts),
      reaching: reaching,
      call_sites: Enum.flat_map(parts, & &1.call_sites),
      origins_index:
        if(reaching,
          do: Enum.reduce(parts, %{}, &Map.merge(&2, &1.origins_index)),
          else: %{}
        )
    })
  end

  defp merge_typed(parts) do
    parts
    |> Enum.reduce(%{}, fn part, rows ->
      Enum.reduce(part.typed || %{}, rows, fn {relation, own}, rows ->
        Map.update(rows, relation, [own], &[own | &1])
      end)
    end)
    |> Map.new(fn {relation, chunks} ->
      {relation, chunks |> Enum.reverse() |> Enum.concat()}
    end)
  end
end
