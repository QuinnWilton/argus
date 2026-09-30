defmodule Argus.Extractor.Shapes do
  @moduledoc """
  Tuple return values used to classify callback replies and helper results.

  Follows the writes reaching each return, including copies and control-flow
  joins. A tuple built elsewhere in the function is not necessarily returned.
  """

  alias Argus.Extractor.Resolve
  alias Argus.Instr

  @doc """
  Returns `{construction_index, elements}` for each tuple that can reach a
  return's `x0`, in instruction order. Each construction appears once.

  Recognizes `put_tuple2`, literal tuples, and immediate returns built with
  legacy `put_tuple`/`put` instructions. Elements use BEAM operands such as
  `{:atom, value}`, `{:integer, value}`, `{:literal, value}`, or registers.
  """
  @spec return_shapes([tuple() | atom()]) :: [{non_neg_integer(), [term()]}]
  def return_shapes(instrs) do
    {tuples, returns, legacy, _direct} =
      instrs
      |> Enum.with_index()
      |> Enum.reduce({%{}, [], [], nil}, fn
        {:return, idx}, {tuples, returns, legacy, direct} ->
          {tuples, [{idx, direct} | returns], legacy, nil}

        {{:put_tuple2, dst, {:list, elements}}, idx}, {tuples, returns, legacy, _direct} ->
          {Map.put(tuples, idx, elements), returns, legacy, direct_write(dst, idx)}

        {{:move, {:literal, tuple}, dst}, idx}, {tuples, returns, legacy, _direct}
        when is_tuple(tuple) and tuple_size(tuple) > 0 ->
          elements = tuple |> Tuple.to_list() |> Enum.map(&literal_element/1)
          {Map.put(tuples, idx, elements), returns, legacy, direct_write(dst, idx)}

        {{:put_tuple, _size, {:x, 0}}, idx}, {tuples, returns, legacy, _direct} ->
          {tuples, returns, legacy_tuple(instrs, idx) ++ legacy, nil}

        {{op, _}, _idx}, acc when op in [:line, :deallocate] ->
          acc

        {{:trim, _, _}, _idx}, acc ->
          acc

        _instruction, {tuples, returns, legacy, _direct} ->
          {tuples, returns, legacy, nil}
      end)

    returned =
      if map_size(tuples) == 0 do
        []
      else
        for {idx, direct} <- returns,
            writer <- if(direct, do: [direct], else: Resolve.writers(instrs, idx, {:x, 0})),
            {:ok, elements} <- [Map.fetch(tuples, writer)],
            do: {writer, elements}
      end

    (returned ++ legacy) |> Enum.uniq() |> Enum.sort()
  end

  # The usual tuple-to-x0 followed by return needs no reaching-definitions walk.
  # Labels and all other instructions clear this shortcut, preserving joins.
  defp direct_write(dst, idx), do: if(Instr.register(dst) == {:x, 0}, do: idx)

  defp literal_element(atom) when is_atom(atom), do: {:atom, atom}
  defp literal_element(int) when is_integer(int), do: {:integer, int}
  defp literal_element(term), do: {:literal, term}

  # Pre-OTP-24 tuple builders have implicit writes that reaching definitions
  # do not model. Preserve their supported straight-line return form.
  defp legacy_tuple(instrs, idx) do
    {puts, rest} =
      instrs |> Enum.drop(idx + 1) |> Enum.split_while(&match?({:put, _}, &1))

    if return_follows?(rest),
      do: [{idx, Enum.map(puts, fn {:put, element} -> element end)}],
      else: []
  end

  defp return_follows?([:return | _]), do: true
  defp return_follows?([{:line, _} | rest]), do: return_follows?(rest)
  defp return_follows?([{:deallocate, _} | rest]), do: return_follows?(rest)
  defp return_follows?([{:trim, _, _} | rest]), do: return_follows?(rest)
  defp return_follows?(_), do: false
end
