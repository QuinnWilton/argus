defmodule Argus.Cfg.Function do
  @moduledoc """
  One function's control-flow graph: basic blocks, typed edges, dominators,
  post-dominators, and loop headers, plus lookup helpers.

  `rpo`, `idom`, `dom_children` and `loop_headers` cover only blocks reachable
  from the entry block (id 0); unreachable blocks still exist in `blocks` so
  the ranges always partition the instruction stream. `ipdom` covers only
  blocks with a path to the function exit — a block whose post-dominator is
  the virtual exit maps to `:exit`; blocks that never reach it (genuine
  infinite loops) are absent.
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
    ipdom: %{},
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
          ipdom: %{Block.id() => Block.id() | :exit},
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
  Whether block `a` post-dominates block `b` (reflexively): every path from
  `b` to the function exit passes through `a`. `false` when `b` has no path
  to the exit.
  """
  @spec postdominates?(t(), Block.id(), Block.id()) :: boolean()
  def postdominates?(%__MODULE__{} = fun, a, b) do
    cond do
      a == b -> Map.has_key?(fun.ipdom, b)
      b == :exit or not Map.has_key?(fun.ipdom, b) -> false
      true -> postdominates?(fun, a, Map.fetch!(fun.ipdom, b))
    end
  end

  @doc """
  Block-level control dependence (Ferrante–Ottenstein–Warren): block `t` is
  control-dependent on branch block `b` when `b`'s decision determines
  whether `t` runs — `t` post-dominates one of `b`'s successors but not `b`
  itself. Returns `%{dependent => [deciding blocks]}`.

  Computed by walking each successor of a multi-way branch up the
  post-dominator tree until (exclusive) `ipdom(b)`. Blocks with no
  post-dominator end the walk, so control dependence through code that
  never reaches the exit is conservatively absent.
  """
  @spec control_deps(t()) :: %{Block.id() => [Block.id()]}
  def control_deps(%__MODULE__{} = fun) do
    pairs =
      for {branch_id, block} <- fun.blocks,
          targets = block.succs |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
          length(targets) >= 2,
          succ <- targets,
          dependent <- pdom_walk(succ, Map.get(fun.ipdom, branch_id, :exit), fun.ipdom),
          do: {dependent, branch_id}

    pairs
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {dependent, deciders} -> {dependent, Enum.sort(deciders)} end)
  end

  defp pdom_walk(node, stop, ipdom, acc \\ [])
  defp pdom_walk(node, stop, _ipdom, acc) when node == stop, do: acc
  defp pdom_walk(:exit, _stop, _ipdom, acc), do: acc

  defp pdom_walk(node, stop, ipdom, acc) do
    case Map.fetch(ipdom, node) do
      {:ok, next} -> pdom_walk(next, stop, ipdom, [node | acc])
      :error -> [node | acc]
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
