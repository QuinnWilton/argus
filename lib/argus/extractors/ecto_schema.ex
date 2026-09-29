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

  Each field's type comes from `__schema__/2`, compiled the same way: a
  `select_val` on the key, then one on the field for `:type`, then a
  literal per field. A type is what a reader of the schema is told about
  a field beyond its name — `Sequin.Encrypted.Field` says the value is a
  secret someone thought worth encrypting, `{:embeds_one,
  Sequin.Sinks.Gcp.Credentials}` what an opaque `credentials` holds — and
  `Argus.Priors.Questions.Sensitivity` hands it to the model with the
  name. It is spelled for that reader: a primitive by name (`string`), a
  custom type by its module, an embed as `embeds_one Mod` or
  `embeds_many Mod`, a collection as `array of string`; a type in any
  other shape, or a schema whose `__schema__/2` is not that dispatch, is
  `dynamic`.

  ## Emitted facts

  - `schema_field(mod, field, type)` — a persisted field and its type
  - `redacted_field(mod, field)` — one excluded from `inspect/1`
  - `lineless_schema(mod)` — a schema whose `__schema__/1` carries no
    line: an `embeds_one :totp, TOTP do ... end` block compiles its
    module with none, so a finding about its fields is anchored at the
    schema that embeds it
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Terms, only: [list_elements: 1]

  @keys %{fields: :schema_field, redact_fields: :redacted_field}

  @impl true
  def relations,
    do: [
      :lineless_schema,
      :redacted_field,
      :schema_field
    ]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    case find_function(functions, 1) do
      nil ->
        %{}

      instrs ->
        mod_str = inspect(mod)
        labels = label_index(instrs)
        dispatch = dispatch_table(instrs, {:x, 0})
        types = field_types(find_function(functions, 2))

        start = if lineless?(instrs), do: add_fact(%{}, :lineless_schema, [mod_str]), else: %{}

        Enum.reduce(@keys, start, fn {key, relation}, facts ->
          dispatch
          |> Map.get(key)
          |> literal_at(labels, instrs)
          |> schema_values()
          |> Enum.filter(&is_atom/1)
          |> Enum.reduce(facts, fn field, acc ->
            add_fact(acc, relation, row(relation, mod_str, field, types))
          end)
        end)
    end
  end

  defp row(:schema_field, mod, field, types),
    do: [mod, inspect(field), Map.get(types, field, "dynamic")]

  defp row(:redacted_field, mod, field, _types), do: [mod, inspect(field)]

  # Every line marker in the function names no location (reference 0, or
  # `[]` from OTP 29's disassembler): the module was compiled from a
  # block that carries none.
  defp lineless?(instrs) do
    markers = for {:line, marker} <- instrs, do: marker
    markers != [] and Enum.all?(markers, &(&1 in [0, []]))
  end

  defp find_function(functions, arity) do
    Enum.find_value(functions, fn
      {:function, :__schema__, ^arity, _, instrs} -> instrs
      _ -> nil
    end)
  end

  # `__schema__(:type, field)`: the key's clause dispatches on the field,
  # and each field's clause returns its type as a literal.
  defp field_types(nil), do: %{}

  defp field_types(instrs) do
    labels = label_index(instrs)

    with label when is_integer(label) <- Map.get(dispatch_table(instrs, {:x, 0}), :type),
         {:ok, idx} <- Map.fetch(labels, label),
         {:select_val, {:x, 1}, _fail, {:list, pairs}} <- Enum.at(instrs, idx + 1) do
      for {field, field_label} <- pairs(pairs), into: %{} do
        case value_at(field_label, labels, instrs) do
          {:ok, type} -> {field, type_name(type)}
          :error -> {field, "dynamic"}
        end
      end
    else
      _ -> %{}
    end
  end

  @doc """
  A type as the model reads it: a primitive by name, a custom or
  parameterized type by its module, an embed by what it embeds, a
  collection by what it holds, and `dynamic` for any other shape.
  """
  @spec type_name(term()) :: String.t()
  def type_name(type) when is_atom(type) and not is_nil(type),
    do: type |> inspect() |> String.trim_leading(":")

  def type_name({:parameterized, {Ecto.Embedded, embed}}), do: embed_name(embed)
  def type_name({:parameterized, Ecto.Embedded, embed}), do: embed_name(embed)
  def type_name({:parameterized, {mod, _params}}) when is_atom(mod), do: type_name(mod)
  def type_name({:parameterized, mod, _params}) when is_atom(mod), do: type_name(mod)
  def type_name({:array, inner}), do: "array of " <> type_name(inner)
  def type_name({:map, inner}), do: "map of " <> type_name(inner)
  def type_name(_other), do: "dynamic"

  defp embed_name(%{cardinality: :many, related: related}) when is_atom(related),
    do: "embeds_many " <> inspect(related)

  defp embed_name(%{cardinality: :one, related: related}) when is_atom(related),
    do: "embeds_one " <> inspect(related)

  defp embed_name(_other), do: "dynamic"

  defp dispatch_table(instrs, reg) do
    Enum.find_value(instrs, %{}, fn
      {:select_val, ^reg, _fail, {:list, pairs}} -> Map.new(pairs(pairs))
      _ -> false
    end)
  end

  defp pairs(pairs) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [{:atom, key}, {:f, label}] -> [{key, label}]
      _ -> []
    end)
  end

  defp label_index(instrs) do
    for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}
  end

  # An improper list is no list of fields.
  defp schema_values(value) when is_list(value), do: list_elements(value)
  defp schema_values(value), do: List.wrap(value)

  # A key's clause is a literal moved into {x,0} and returned. Anything
  # else — a computed value, a call — yields nothing rather than a guess;
  # a list key's clause holds a list literal, a type's an atom or a tuple.
  defp literal_at(label, labels, instrs) do
    case value_at(label, labels, instrs) do
      {:ok, value} when is_list(value) -> value
      _ -> []
    end
  end

  defp value_at(nil, _labels, _instrs), do: :error

  defp value_at(label, labels, instrs) do
    case Map.fetch(labels, label) do
      :error ->
        :error

      {:ok, idx} ->
        instrs
        |> Enum.drop(idx + 1)
        |> Enum.take(3)
        |> Enum.find_value(:error, fn
          {:move, {:literal, value}, {:x, 0}} -> {:ok, value}
          {:move, {:atom, value}, {:x, 0}} -> {:ok, value}
          _ -> false
        end)
    end
  end
end
