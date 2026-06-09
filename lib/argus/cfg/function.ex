defmodule Argus.Cfg.Function do
  @moduledoc """
  One function's control-flow graph: basic blocks, typed edges, dominators,
  and loop headers, plus lookup helpers.

  `rpo`, `idom`, `dom_children` and `loop_headers` cover only blocks reachable
  from the entry block (id 0); unreachable blocks still exist in `blocks` so
  the ranges always partition the instruction stream.
  """

  alias Argus.Cfg.Block

  @enforce_keys [:func, :arity, :entry, :blocks, :rpo]
  defstruct [
    :func,
    :arity,
    :entry,
    :blocks,
    :rpo,
    idom: %{},
    dom_children: %{},
    loop_headers: MapSet.new(),
    labels: %{},
    selects: []
  ]

  @type select :: %{
          idx: non_neg_integer(),
          arms: %{String.t() => Block.id()},
          default: Block.id() | nil
        }

  @type t :: %__MODULE__{
          func: String.t(),
          arity: non_neg_integer(),
          entry: Block.id(),
          blocks: %{Block.id() => Block.t()},
          rpo: [Block.id()],
          idom: %{Block.id() => Block.id()},
          dom_children: %{Block.id() => [Block.id()]},
          loop_headers: MapSet.t(Block.id()),
          labels: %{non_neg_integer() => Block.id()},
          selects: [select()]
        }

  @doc "The block containing the instruction at `idx`, or `nil`."
  @spec block_at(t(), non_neg_integer()) :: Block.t() | nil
  def block_at(%__MODULE__{blocks: blocks}, idx) do
    Enum.find_value(blocks, fn {_id, %Block{range: {first, last}} = block} ->
      if idx >= first and idx <= last, do: block
    end)
  end

  @doc """
  Whether block `a` dominates block `b` (reflexively). `false` when `b` is
  unreachable from the entry.
  """
  @spec dominates?(t(), Block.id(), Block.id()) :: boolean()
  def dominates?(%__MODULE__{} = fun, a, b) do
    cond do
      a == b -> b == fun.entry or Map.has_key?(fun.idom, b)
      not Map.has_key?(fun.idom, b) -> false
      true -> dominates?(fun, a, Map.fetch!(fun.idom, b))
    end
  end

  @doc """
  The single-entry region rooted at `block_id`: the block plus everything it
  dominates, in ascending block order.
  """
  @spec region(t(), Block.id()) :: [Block.id()]
  def region(%__MODULE__{} = fun, block_id) do
    collect_region(fun, [block_id], %{}) |> Map.keys() |> Enum.sort()
  end

  @spec collect_region(t(), [Block.id()], %{Block.id() => true}) :: %{Block.id() => true}
  defp collect_region(_fun, [], acc), do: acc

  defp collect_region(fun, [id | rest], acc) do
    if Map.has_key?(acc, id) do
      collect_region(fun, rest, acc)
    else
      children = Map.get(fun.dom_children, id, [])
      collect_region(fun, children ++ rest, Map.put(acc, id, true))
    end
  end
end
