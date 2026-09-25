defmodule Argus.Cfg.Function do
  @moduledoc """
  One function's control-flow graph: basic blocks, typed edges, dominators,
  post-dominators, and loop headers, plus lookup helpers.

  Block ids number the blocks in instruction order from 0, and the
  blocks' ranges partition the instruction stream.

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

  @doc """
  The block containing the instruction at `idx`, or `nil`: a binary
  search, since block ids number the blocks in instruction order.
  """
  @spec block_at(t(), non_neg_integer()) :: Block.t() | nil
  def block_at(%__MODULE__{blocks: blocks}, idx), do: search(blocks, idx, 0, map_size(blocks) - 1)

  defp search(_blocks, _idx, lo, hi) when lo > hi, do: nil

  defp search(blocks, idx, lo, hi) do
    mid = div(lo + hi, 2)
    %Block{range: {first, last}} = block = Map.fetch!(blocks, mid)

    cond do
      idx < first -> search(blocks, idx, lo, mid - 1)
      idx > last -> search(blocks, idx, mid + 1, hi)
      true -> block
    end
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
  Whether control can pass from instruction `from` to instruction `to`
  within one trip through the function: later in the same block, or in a
  block the forward edges lead to. An edge into a block that dominates
  its source closes a loop; following it would order two effects in one
  loop body both ways, when each iteration makes them in one order.
  """
  @spec precedes?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def precedes?(%__MODULE__{} = fun, from, to) do
    case {block_at(fun, from), block_at(fun, to)} do
      {nil, _} -> false
      {_, nil} -> false
      {%Block{id: same}, %Block{id: same}} -> from < to
      {a, %Block{id: target}} -> reach_block(fun, forward(fun, a), target, %{})
    end
  end

  defp reach_block(_fun, [], _target, _seen), do: false

  defp reach_block(fun, [id | rest], target, seen) do
    cond do
      id == target ->
        true

      Map.has_key?(seen, id) ->
        reach_block(fun, rest, target, seen)

      true ->
        next = forward(fun, Map.fetch!(fun.blocks, id))
        reach_block(fun, next ++ rest, target, Map.put(seen, id, true))
    end
  end

  defp forward(fun, %Block{id: id, succs: succs}) do
    succs
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&dominates?(fun, &1, id))
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

  @doc """
  The blocks every path from the entry to a completion passes through: a
  return or a tail call, not a raise. `nil` when no path completes.

  A path that raises is no run of the function a caller goes on from: a
  clause head that fails into `func_info` (Erlang's `init([]) ->`), a
  `{:ok, pid} = start()` whose other side is a badmatch, a case whose
  default is a `case_end`. `control_deps/1` counts the raising side as a
  way the function can go, so every call after such a test is
  control-dependent on it; here the test decides nothing, and what
  follows it runs whenever the function completes. A block only raising
  paths reach is on none of these, so it is not in the set.

  They are the dominators of a virtual exit every completion leads to, in
  the graph of the blocks that can complete: the exit's dominator chain.
  """
  @spec completing_blocks(t()) :: MapSet.t(Block.id()) | nil
  def completing_blocks(%__MODULE__{blocks: blocks, entry: entry}) do
    completes = completing(blocks)

    if MapSet.member?(completes, entry) do
      succs =
        Map.new(completes, fn id ->
          block = Map.fetch!(blocks, id)

          edges =
            if block.terminator in [:return, :tail_call],
              do: [{:exit, :virtual}],
              else:
                for(
                  {to, kind} <- block.succs,
                  MapSet.member?(completes, to),
                  uniq: true,
                  do: {to, kind}
                )

          {id, edges}
        end)

      preds =
        Enum.reduce(succs, %{}, fn {from, edges}, acc ->
          Enum.reduce(edges, acc, fn {to, kind}, a ->
            Map.update(a, to, [{from, kind}], &[{from, kind} | &1])
          end)
        end)

      idom = Argus.Cfg.dominator_tree(entry, preds, succs)
      idom |> Map.fetch!(:exit) |> chain(idom, entry, []) |> MapSet.new()
    end
  end

  defp chain(node, _idom, entry, acc) when node == entry, do: [node | acc]

  defp chain(node, idom, entry, acc),
    do: chain(Map.fetch!(idom, node), idom, entry, [node | acc])

  # The blocks with a path to a return or a tail call. The walk keeps a
  # plain map, not a MapSet: dialyzer rejects an opaque term threaded
  # through recursion.
  defp completing(blocks) do
    exits =
      for {id, %Block{terminator: t}} <- blocks, t in [:return, :tail_call], do: id

    exits |> grow(Map.new(exits, &{&1, true}), blocks) |> Map.keys() |> MapSet.new()
  end

  defp grow([], seen, _blocks), do: seen

  defp grow([id | rest], seen, blocks) do
    new =
      for {pred, _kind} <- Map.fetch!(blocks, id).preds,
          Map.has_key?(blocks, pred),
          not Map.has_key?(seen, pred),
          uniq: true,
          do: pred

    grow(new ++ rest, Enum.reduce(new, seen, &Map.put(&2, &1, true)), blocks)
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
