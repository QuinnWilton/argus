defmodule Argus.Extractors.TermFlow.Heap do
  @moduledoc """
  Allocation-site heap for intraprocedural source flow.

  Objects have source sets in `fields`, inherited sources in `base`, and
  definitely overwritten selectors in `keys`. Reads follow bases unless an
  overwrite shadows them. External containers produce deferred loads; local
  objects produce values and dependencies, even when their fields are empty.
  Cycles are visited once per read, so allocation-site recursion terminates.

  `[]` merges list elements. `*` represents unknown map keys; an unknown-key
  read follows only `*`, deliberately omitting known fields. This is a partial
  provenance model, not a sound abstraction of all possible runtime values.
  """

  @type value :: MapSet.t(term())
  @type object :: %{
          required(:shape) => String.t(),
          required(:fields) => %{String.t() => value()},
          required(:base) => value(),
          required(:keys) => MapSet.t(String.t()),
          optional(:tag) => String.t(),
          optional(:arity) => non_neg_integer(),
          optional(:nil_tail) => boolean()
        }
  @type objects :: %{term() => object()}
  @type state :: %{objs: objects(), readers: %{term() => MapSet.t(non_neg_integer())}}
  @type read_result :: {value(), [term()], [{String.t(), String.t(), term()}]}

  @doc "Commit objects and record readers; return readers of changed objects."
  @spec commit(non_neg_integer(), [{term(), object()}], [term()], state()) ::
          {[non_neg_integer()], state()}
  def commit(idx, objects, dependencies, state) do
    readers =
      Enum.reduce(dependencies, state.readers, fn key, acc ->
        Map.update(acc, key, MapSet.new([idx]), &MapSet.put(&1, idx))
      end)

    {changed, objs} =
      Enum.reduce(Map.new(objects), {[], state.objs}, fn {key, obj}, {changed, objs} ->
        if Map.get(objs, key) == obj,
          do: {changed, objs},
          else: {[key | changed], Map.put(objs, key, obj)}
      end)

    again =
      changed
      |> Enum.flat_map(&MapSet.to_list(Map.get(readers, &1, MapSet.new())))
      |> Enum.uniq()
      |> Enum.sort()

    {again, %{state | objs: objs, readers: readers}}
  end

  @doc "Read a selector, returning `{sources, object_dependencies, deferred_loads}`."
  @spec read(objects(), value(), String.t(), String.t()) :: read_result()
  def read(objs, value, sel, id) do
    {sources, dependencies, loads} = walk(MapSet.to_list(value), objs, sel, id, %{}, {[], [], []})
    {MapSet.new(sources), dependencies, loads}
  end

  defp walk([], _objs, _sel, _id, _seen, result), do: result

  defp walk([{:obj, key} | rest], objs, sel, id, seen, result) do
    if Map.has_key?(seen, key) do
      walk(rest, objs, sel, id, seen, result)
    else
      seen = Map.put(seen, key, true)
      {sources, dependencies, loads} = result
      result = {sources, [key | dependencies], loads}

      case Map.get(objs, key) do
        nil ->
          walk(rest, objs, sel, id, seen, result)

        obj ->
          result = {MapSet.to_list(own_field(obj, sel)) ++ sources, [key | dependencies], loads}
          inherited = if MapSet.member?(obj.keys, sel), do: [], else: MapSet.to_list(obj.base)
          walk(inherited ++ rest, objs, sel, id, seen, result)
      end
    end
  end

  defp walk([{kind, _} = token | rest], objs, sel, id, seen, {sources, dependencies, loads})
       when kind in [:param, :result, :load, :reply, :dict] do
    result = {[{:load, id} | sources], dependencies, [{id, sel, token} | loads]}
    walk(rest, objs, sel, id, seen, result)
  end

  defp walk([_scalar | rest], objs, sel, id, seen, result),
    do: walk(rest, objs, sel, id, seen, result)

  @spec own_field(object(), String.t()) :: value()
  defp own_field(obj, sel) do
    own = Map.get(obj.fields, sel, MapSet.new())

    if obj.shape == "map" and sel != "*",
      do: MapSet.union(own, Map.get(obj.fields, "*", MapSet.new())),
      else: own
  end

  @doc "Objects transitively containing a source, excluding bare closures."
  @spec live(objects()) :: %{term() => true}
  def live(objs), do: live(objs, %{})

  defp live(objs, known) do
    grown =
      Enum.reduce(objs, known, fn {key, obj}, acc ->
        values = [obj.base | Map.values(obj.fields)]

        if Enum.any?(values, fn value -> Enum.any?(value, &source?(&1, acc)) end),
          do: Map.put(acc, key, true),
          else: acc
      end)

    if map_size(grown) == map_size(known), do: grown, else: live(objs, grown)
  end

  defp source?({:obj, key}, known), do: Map.has_key?(known, key)
  defp source?({:fun, _}, _known), do: false
  defp source?(_token, _known), do: true

  @doc "Positional elements of an unambiguous, locally built proper list."
  @spec list_elements(objects(), value()) :: {:ok, [value()]} | :unknown
  def list_elements(objs, value), do: list_elements(objs, value, %{})

  @spec list_elements(objects(), value(), map()) :: {:ok, [value()]} | :unknown
  defp list_elements(objs, value, seen) do
    case MapSet.to_list(value) do
      [{:obj, key}] ->
        if Map.has_key?(seen, key),
          do: :unknown,
          else: list_object(objs, Map.get(objs, key), Map.put(seen, key, true))

      _empty_or_ambiguous ->
        :unknown
    end
  end

  @spec list_object(objects(), object() | nil, map()) :: {:ok, [value()]} | :unknown
  defp list_object(objs, %{shape: "list", fields: %{"[]" => head}, base: tail} = obj, seen) do
    if obj.nil_tail do
      {:ok, [head]}
    else
      case list_elements(objs, tail, seen) do
        {:ok, rest} -> {:ok, [head | rest]}
        :unknown -> :unknown
      end
    end
  end

  defp list_object(_objs, _obj, _seen), do: :unknown
end
