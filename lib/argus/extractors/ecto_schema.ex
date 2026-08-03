defmodule Argus.Extractors.EctoSchema do
  @moduledoc """
  Ecto schema fields, and which of them are redacted.

  `redact: true` excludes a field from `inspect/1`. It defaults to off, so a
  struct holding a credential prints it in full — into logs, crash reports,
  LiveView debug output and whatever error reporter is installed. Nothing at
  the field's definition site suggests that.

  Both lists are compiled into `__schema__/1`, which dispatches on its
  argument with a `select_val` and returns a literal per key:

      {:select_val, {:x, 0}, {:f, 12},
        {:list, [atom: :fields, f: 20, atom: :redact_fields, f: 19, ...]}}
      ...
      {:label, 20}
      {:move, {:literal, [:id, :smtp_password, ...]}, {:x, 0}}
      :return

  So this reads the module rather than calling it. Loading a project's
  modules to ask them questions would run their `@on_load` and module bodies
  in the analyzer, which is not a thing an analysis should do to code it was
  pointed at.

  ## Emitted facts

  - `schema_field(mod, field)` — a persisted field
  - `redacted_field(mod, field)` — one excluded from `inspect/1`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  @keys %{fields: :schema_field, redact_fields: :redacted_field}

  @impl true
  def extract(%{module: mod, functions: functions}) do
    case Enum.find(functions, &match?({:function, :__schema__, 1, _, _}, &1)) do
      nil ->
        %{}

      {:function, _, _, _, instrs} ->
        mod_str = inspect(mod)
        labels = label_index(instrs)
        dispatch = dispatch_table(instrs)

        Enum.reduce(@keys, %{}, fn {key, relation}, facts ->
          dispatch
          |> Map.get(key)
          |> literal_at(labels, instrs)
          |> List.wrap()
          |> Enum.filter(&is_atom/1)
          |> Enum.reduce(facts, &add_fact(&2, relation, [mod_str, inspect(&1)]))
        end)
    end
  end

  defp dispatch_table(instrs) do
    Enum.find_value(instrs, %{}, fn
      {:select_val, {:x, 0}, _fail, {:list, pairs}} ->
        pairs
        |> Enum.chunk_every(2)
        |> Enum.flat_map(fn
          [{:atom, key}, {:f, label}] -> [{key, label}]
          _ -> []
        end)
        |> Map.new()

      _ ->
        false
    end)
  end

  defp label_index(instrs) do
    for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}
  end

  # A key's clause is a literal moved into {x,0} and returned. Anything
  # else — a computed value, a call — yields nothing rather than a guess.
  defp literal_at(nil, _labels, _instrs), do: []

  defp literal_at(label, labels, instrs) do
    case Map.fetch(labels, label) do
      :error ->
        []

      {:ok, idx} ->
        instrs
        |> Enum.drop(idx + 1)
        |> Enum.take(3)
        |> Enum.find_value([], fn
          {:move, {:literal, value}, {:x, 0}} -> value
          _ -> false
        end)
    end
  end
end
