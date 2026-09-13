defmodule Argus.Cfg.Walk do
  @moduledoc """
  Forward, all-paths walks over a function's control flow, one instruction
  at a time.

  Three extractors used to carry their own copy of this loop — one
  deciding whether a deferred reply ever read `from`, one whether a
  monitor ref was ever read, one whether a clause head accepts any
  content — and their `successors/3` functions disagreed with each other
  about which instructions end a path. Here the block graph decides:
  within a block execution is sequential, at the block's end it takes
  every edge the caller allows, and a block whose terminator returns,
  raises or tail-calls has no edges to take.

  The walk starts at instruction indices, not blocks, because the
  interesting starting points are "just after this test succeeded", which
  is the middle of a block as often as not.
  """

  alias Argus.Cfg.{Block, Function}

  @typedoc """
  What the caller decides at each instruction: keep walking, stop this
  path here (its successors are not explored), or stop the whole walk with
  an answer.
  """
  @type verdict :: :continue | :prune | {:halt, term()}

  @type option ::
          {:on_instr, (tuple(), non_neg_integer() -> verdict())}
          | {:follow?, (tuple(), Block.edge_kind() -> boolean())}

  @doc """
  Explores every path from `starts`, calling `on_instr` at each
  instruction reached and `follow?` at each edge out of a block (given
  the block's last instruction and the edge kind). Returns `{:halted,
  answer}` the moment a verdict halts, or `{:done, visited}` with the set
  of instruction indices reached.
  """
  @spec explore(Function.t(), [tuple()], [non_neg_integer() | nil], [option()]) ::
          {:halted, term()} | {:done, MapSet.t(non_neg_integer())}
  def explore(%Function{} = fun, instrs, starts, opts) do
    on_instr = Keyword.get(opts, :on_instr, fn _instr, _idx -> :continue end)
    follow? = Keyword.get(opts, :follow?, fn _instr, _kind -> true end)

    state = %{
      instrs: List.to_tuple(instrs),
      blocks: fun.blocks,
      block_of: block_index(fun),
      on_instr: on_instr,
      follow?: follow?
    }

    walk(Enum.reject(starts, &is_nil/1), state, MapSet.new())
  end

  defp walk([], _state, visited), do: {:done, visited}

  defp walk([idx | rest], state, visited) do
    cond do
      idx >= tuple_size(state.instrs) or MapSet.member?(visited, idx) ->
        walk(rest, state, visited)

      true ->
        instr = elem(state.instrs, idx)
        visited = MapSet.put(visited, idx)

        case state.on_instr.(instr, idx) do
          {:halt, answer} -> {:halted, answer}
          :prune -> walk(rest, state, visited)
          :continue -> walk(next(instr, idx, state) ++ rest, state, visited)
        end
    end
  end

  # Inside a block the next instruction follows; at the block's last
  # instruction the allowed out-edges lead to their blocks' first
  # instructions.
  defp next(instr, idx, state) do
    case Map.get(state.block_of, idx) do
      %Block{range: {_first, last}} = block when last == idx ->
        for {to, kind} <- block.succs,
            state.follow?.(instr, kind),
            %Block{range: {first, _}} = Map.fetch!(state.blocks, to),
            do: first

      _ ->
        [idx + 1]
    end
  end

  defp block_index(%Function{blocks: blocks}) do
    for {_id, %Block{range: {first, last}} = block} <- blocks,
        idx <- first..last,
        into: %{},
        do: {idx, block}
  end
end
