defmodule Argus.Extractor.Terms do
  @moduledoc """
  Questions about a term a beam holds — a literal, an attribute's value,
  a value `Argus.Extractor.Resolve` rebuilt — that `Enum` and `inspect/2`
  answer wrongly or not at all: how a fact column spells it
  (`spell/1`), whether it is a list anything may enumerate
  (`proper_list?/1`, `list_elements/1`), and whether some part of it
  satisfies a predicate (`mentions?/2` for an instruction's operands,
  `value_contains?/2` for a value).
  """

  @doc """
  A value as every fact column spells it: `inspect/2` without a struct's
  own `Inspect` implementation, and with a digest of the whole term when
  inspect cut the spelling short.

  Never a struct's own implementation, because a spelling must not depend
  on which modules are loaded (a run inside the project's VM has the
  analyzed code loaded, the escript does not), and an implementation
  that raises on the struct's defaults (sequin's `CircularBuffer`)
  renders as a multi-line `#Inspect.Error<...>`.

  A map prints its keys sorted: a VM iterates a small map with atom keys
  in atom-table order, which depends on which atoms that VM created
  first, so the same beam read by two VMs would otherwise spell the same
  literal two ways.

  inspect/2 stops at 50 elements and 4096 bytes of a string, so two
  values that differ past those bounds spelled the same, and joined as
  one value (one ETS key, one literal). A spelling inspect cut short
  carries ` #` and a digest of the whole term instead. Spelling every
  value in full was measured and rejected: over ecto, absinthe and
  hexpm it doubles the bytes of literal spellings (6.4MB to 12.7MB,
  nearly all of it embedded asset binaries that land in `literal_value`
  and every `move` of them), where the digest adds 0.4% and touches 995
  of 91,640 spellings. The test is for inspect's `...` marker; a small
  value that merely holds three dots gets a digest it did not need,
  which costs nothing.
  """
  @spec spell(term()) :: String.t()
  def spell(value) do
    spelled = inspect(value, structs: false, custom_options: [sort_maps: true])

    if String.contains?(spelled, "...") do
      digest =
        :sha256
        |> :crypto.hash(:erlang.term_to_binary(value, [:deterministic]))
        |> binary_part(0, 12)
        |> Base.encode16(case: :lower)

      spelled <> " #" <> digest
    else
      spelled
    end
  end

  @doc """
  Whether `term` is a proper list: `[]`, or cons cells ending in `[]`.

  A literal in a beam can be improper (`[a | :b]`, Erlang's
  `-attr([a|b]).`, an iolist `["x" | "y"]`), and `Enum`, `length/1`,
  `++`, `Keyword` and `in` all raise on one. Ask this before handing a
  literal or a resolved value to any of them; `is_list/1` is not enough.
  """
  @spec proper_list?(term()) :: boolean()
  def proper_list?([]), do: true
  def proper_list?([_ | tail]), do: proper_list?(tail)
  def proper_list?(_), do: false

  @doc """
  The elements of `term` when it is a proper list, and `[]` otherwise:
  what a walk over a literal list can safely enumerate. An improper list
  is a value the runtime would reject wherever a list is expected, so
  reading nothing from it is the quiet answer.
  """
  @spec list_elements(term()) :: list()
  def list_elements(term), do: if(proper_list?(term), do: term, else: [])

  @doc """
  Whether `pred` holds for any part of an instruction or operand: the
  term itself, then every element of its tuples and lists, improper
  tails included.

  A `{:literal, value}` operand is asked about as a whole but not entered.
  Its value is data, not operands: the literal `{:x, 1}` is not the
  register x1, and a walk that went inside took one for a read of the
  register. Use `value_contains?/2` to search a literal's value. (What an
  instruction reads and writes is `Argus.Instr`'s to say; this is for
  a question about operands it does not answer.)
  """
  @spec mentions?(term(), (term() -> boolean())) :: boolean()
  def mentions?(term, pred) do
    pred.(term) or mentions_within?(term, pred)
  end

  defp mentions_within?({:literal, _value}, _pred), do: false

  defp mentions_within?(term, pred) when is_tuple(term),
    do: term |> Tuple.to_list() |> any_element?(pred, &mentions?/2)

  defp mentions_within?(term, pred) when is_list(term), do: any_element?(term, pred, &mentions?/2)
  defp mentions_within?(_term, _pred), do: false

  @doc """
  Whether `pred` holds for any part of a value — a literal's, or one
  `resolve_register/3` rebuilt: the value itself, then every element of
  its tuples, lists (improper tails included) and maps (keys and values,
  structs included).
  """
  @spec value_contains?(term(), (term() -> boolean())) :: boolean()
  def value_contains?(value, pred) do
    pred.(value) or value_contains_within?(value, pred)
  end

  defp value_contains_within?(value, pred) when is_tuple(value),
    do: value |> Tuple.to_list() |> any_element?(pred, &value_contains?/2)

  defp value_contains_within?(value, pred) when is_list(value),
    do: any_element?(value, pred, &value_contains?/2)

  # Map.to_list/1, not Enum: a struct literal (an `Ecto.Query` built at
  # compile time) is a map that need not implement Enumerable.
  defp value_contains_within?(value, pred) when is_map(value),
    do: value |> Map.to_list() |> any_element?(pred, &value_contains?/2)

  defp value_contains_within?(_value, _pred), do: false

  # Enum.any?/2 raises at an improper tail; this asks the tail itself.
  defp any_element?([], _pred, _ask), do: false

  defp any_element?([head | tail], pred, ask),
    do: ask.(head, pred) or any_element?(tail, pred, ask)

  defp any_element?(tail, pred, ask), do: ask.(tail, pred)
end
