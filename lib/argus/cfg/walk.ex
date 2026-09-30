defmodule Argus.Cfg.Walk do
  @moduledoc """
  Forward, all-paths walks over a function's control flow, one instruction
  at a time.

  Execution advances within a block, then follows its outgoing edges.
  Returns, raises and tail calls end paths. Walks can start inside a block,
  for example just after a successful test.

  `explore/4` checks reachability with caller-defined stopping conditions.
  `carries_to_return?/5` follows a value through copies and overwrites.
  """

  alias Argus.Cfg.{Block, Function}
  alias Argus.Instr

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
      fun: fun,
      on_instr: on_instr,
      follow?: follow?
    }

    walk(Enum.reject(starts, &is_nil/1), state, %{})
  end

  @doc """
  Whether the value in `reg` before `start` can reach a return's `x0`.

  Follows copies and control-flow edges, stopping paths where `stop?` is true.
  Each instruction/register pair is visited once, so loops terminate without
  losing distinct copies of the value.
  """
  @spec carries_to_return?(
          Function.t(),
          [Instr.instr()],
          non_neg_integer(),
          Instr.reg(),
          (Instr.instr() -> boolean())
        ) :: boolean()
  def carries_to_return?(%Function{} = fun, instrs, start, reg, stop?) do
    state = %{
      instrs: List.to_tuple(instrs),
      fun: fun,
      stop?: stop?,
      follow?: fn _instr, _kind -> true end
    }

    carries([{start, reg}], state, %{})
  end

  defp carries([], _state, _visited), do: false

  defp carries([{idx, reg} = point | rest], state, visited) do
    if idx >= tuple_size(state.instrs) or Map.has_key?(visited, point) do
      carries(rest, state, visited)
    else
      instr = elem(state.instrs, idx)
      visited = Map.put(visited, point, true)

      cond do
        state.stop?.(instr) ->
          carries(rest, state, visited)

        instr == :return and reg == {:x, 0} ->
          true

        true ->
          held = Instr.carry(instr, [reg])
          following = for at <- next(instr, idx, state), dst <- held, do: {at, dst}
          carries(following ++ rest, state, visited)
      end
    end
  end

  defp walk([], _state, visited), do: {:done, visited |> Map.keys() |> MapSet.new()}

  defp walk([idx | rest], state, visited) do
    if idx >= tuple_size(state.instrs) or Map.has_key?(visited, idx) do
      walk(rest, state, visited)
    else
      instr = elem(state.instrs, idx)
      visited = Map.put(visited, idx, true)

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
    case Function.block_at(state.fun, idx) do
      %Block{range: {_first, last}} = block when last == idx ->
        for {to, kind} <- block.succs,
            state.follow?.(instr, kind),
            %Block{range: {first, _}} = Map.fetch!(state.fun.blocks, to),
            do: first

      _ ->
        [idx + 1]
    end
  end
end
