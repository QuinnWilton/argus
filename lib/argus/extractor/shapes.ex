defmodule Argus.Extractor.Shapes do
  @moduledoc """
  The tuples a function returns, read off its instructions
  (`return_shapes/1`): what an extractor classifying a callback's
  replies, or a helper's `{:ok, _}`/`{:error, _}`, looks at.
  """

  alias Argus.Instr

  @doc """
  Every tuple a function returns, as `{index, elements}`: built by
  `put_tuple2` (into `{x,0}`, or into a register moved to `{x,0}` before
  the return), by the pre-OTP-24 `put_tuple`/`put` sequence, or folded by
  the compiler into one literal moved into `{x,0}`. Elements are in the
  instruction vocabulary — `{:atom, a}`, `{:integer, n}`, `{:literal, t}`,
  a register — whatever their source, so a rule reading `[{:atom, :ok} |
  rest]` reads all three shapes.
  """
  @spec return_shapes([tuple()]) :: [{non_neg_integer(), [term()]}]
  def return_shapes(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      # Built straight into {x,0}: it is the return only if the return is
      # next. A tuple raised with erlang:error/1 sits in {x,0} too, and a
      # later, unrelated return must not claim it.
      {{:put_tuple2, {:x, 0}, {:list, elements}}, idx} ->
        if returns_next?(instrs, idx + 1), do: [{idx, elements}], else: []

      {{:put_tuple2, {:tr, {:x, 0}, _}, {:list, elements}}, idx} ->
        if returns_next?(instrs, idx + 1), do: [{idx, elements}], else: []

      {{:put_tuple2, dst, {:list, elements}}, idx} ->
        if tuple_flows_to_return?(instrs, idx, dst), do: [{idx, elements}], else: []

      {{:put_tuple, _size, {:x, 0}}, idx} ->
        puts = instrs |> Enum.drop(idx + 1) |> Enum.take_while(&match?({:put, _}, &1))

        if returns_next?(instrs, idx + 1 + length(puts)),
          do: [{idx, Enum.map(puts, fn {:put, element} -> element end)}],
          else: []

      {{:move, {:literal, tuple}, {:x, 0}}, idx} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        if returns_next?(instrs, idx + 1),
          do: [{idx, tuple |> Tuple.to_list() |> Enum.map(&literal_element/1)}],
          else: []

      _ ->
        []
    end)
  end

  defp literal_element(atom) when is_atom(atom), do: {:atom, atom}
  defp literal_element(int) when is_integer(int), do: {:integer, int}
  defp literal_element(term), do: {:literal, term}

  # Line markers and frame teardown may sit between the tuple and the
  # return. Anything else means the tuple is not what comes back.
  defp returns_next?(instrs, idx) do
    case Enum.at(instrs, idx) do
      :return -> true
      {:line, _} -> returns_next?(instrs, idx + 1)
      {:deallocate, _} -> returns_next?(instrs, idx + 1)
      {:trim, _, _} -> returns_next?(instrs, idx + 1)
      _ -> false
    end
  end

  # Check whether a put_tuple2 destination register flows to x0 before
  # a return instruction. Handles direct writes to x0 and single-step
  # moves from the destination to x0.
  defp tuple_flows_to_return?(instrs, idx, dst) do
    rest = Enum.drop(instrs, idx + 1)

    case Instr.register(dst) do
      {:x, 0} ->
        # Already in x0 — just check that a return follows without
        # another write to x0.
        Enum.any?(rest, fn
          :return -> true
          instr -> Instr.exits?(instr)
        end)

      other_reg ->
        # Look for a move from the dst register to x0 before return.
        Enum.reduce_while(rest, false, fn
          {:move, src, dst}, _acc ->
            if Instr.register(dst) == {:x, 0} and Instr.register(src) == other_reg,
              do: {:halt, true},
              else: {:cont, false}

          :return, _acc ->
            {:halt, false}

          instr, _acc ->
            if Instr.exits?(instr), do: {:halt, false}, else: {:cont, false}
        end)
    end
  end
end
