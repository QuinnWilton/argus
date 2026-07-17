defmodule Argus.Cfg do
  @moduledoc """
  Basic-block control-flow graphs derived from Layer-1 facts, with dominators
  and loop headers.

  This is the in-process counterpart of `priv/dl/clientlib/cfg.dl`'s flat
  `cfg_edge` derivation, lifted to the block level: instructions are grouped
  into maximal straight-line blocks (the classic leader algorithm), edges
  carry their kind (`Argus.Cfg.Block.edge_kind/0`), and each function gets a
  dominator tree (iterative Cooper–Harvey–Kennedy over reverse postorder) and
  the set of natural-loop headers (back-edge targets).

  The entry block is the one holding the function's *entry label* from
  `function_def` — not instruction 0, which is the `func_info` failure
  landing pad that never falls through.

  Known imprecision, by design: a call to `erlang:raise`/`erlang:error` is an
  ordinary call followed by a (never-taken) fallthrough edge — fail-edge and
  terminator classification is fact-driven, not BIF-name-driven.
  """

  alias Argus.Cfg.{Block, Function}
  alias Argus.InstrId

  @tail_calls ~w(call_only call_ext_only call_last call_ext_last)
  @raises ~w(if_end case_end badmatch try_case_end raw_raise)

  @doc """
  Build per-function CFGs from typed facts (`Argus.Pipeline.extract/2` with
  `format: :typed`).
  """
  @spec build(Argus.Facts.t()) :: %{{String.t(), non_neg_integer()} => Function.t()}
  def build(facts) when is_map(facts) do
    instrs = group(facts, :instruction, fn row -> {row.id.idx, row.op} end)
    labels = group(facts, :label_at, fn row -> {row.label, row.id.idx} end)
    jumps = group(facts, :jump, fn row -> {row.id.idx, row.target} end)

    branches =
      group(facts, :branch, fn row -> if row.fail != 0, do: {row.id.idx, row.fail} end)

    fails =
      group(facts, :bif_call, fn row -> if row.fail != 0, do: {row.id.idx, row.fail} end)
      |> merge_groups(
        group(facts, :bs_start, fn row -> if row.fail != 0, do: {row.id.idx, row.fail} end)
      )

    handlers = group(facts, :try_start, fn row -> {row.id.idx, row.handler} end)

    selects =
      facts
      |> Map.get(:select_branch, [])
      |> Enum.group_by(&InstrId.fa(&1.id))
      |> Map.new(fn {fa, rows} ->
        {fa, Enum.group_by(rows, & &1.id.idx, fn row -> {row.val, row.target} end)}
      end)

    entries =
      facts
      |> Map.get(:function_def, [])
      |> Map.new(fn row -> {{row.name, row.arity}, row.entry} end)

    for {fa, ops} <- instrs, into: %{} do
      fun = %{
        ops: ops,
        labels: Map.get(labels, fa, %{}),
        jumps: Map.get(jumps, fa, %{}),
        branches: Map.get(branches, fa, %{}),
        fails: Map.get(fails, fa, %{}),
        handlers: Map.get(handlers, fa, %{}),
        selects: Map.get(selects, fa, %{}),
        entry_label: Map.get(entries, fa)
      }

      {fa, build_function(fa, fun)}
    end
  end

  # Collect one relation into %{fa => %{key => value}} via a row shaper that
  # returns {key, value} or nil to skip.
  defp group(facts, relation, shape) do
    facts
    |> Map.get(relation, [])
    |> Enum.reduce(%{}, fn row, acc ->
      case shape.(row) do
        nil ->
          acc

        {key, value} ->
          Map.update(acc, InstrId.fa(row.id), %{key => value}, &Map.put(&1, key, value))
      end
    end)
  end

  defp merge_groups(left, right) do
    Map.merge(left, right, fn _fa, l, r -> Map.merge(l, r) end)
  end

  # --- per-function construction --------------------------------------------

  defp build_function({func, arity}, fun) do
    n = fun.ops |> Map.keys() |> Enum.max() |> Kernel.+(1)

    leaders = leaders(fun, n)
    blocks = blocks_from_leaders(leaders, n)
    block_of = Map.new(blocks, fn {id, {first, _last}} -> {first, id} end)

    succs =
      Map.new(blocks, fn {id, {_first, last}} ->
        {id, successors(fun, last, n, block_of)}
      end)

    preds =
      Enum.reduce(succs, %{}, fn {from, edges}, acc ->
        Enum.reduce(edges, acc, fn {to, kind}, a ->
          Map.update(a, to, [{from, kind}], &[{from, kind} | &1])
        end)
      end)

    entry = entry_block(fun, block_of)
    rpo = reverse_postorder(entry, succs)
    idom = dominators(entry, rpo, preds)
    ipdom = postdominators(succs, preds)
    structs = block_structs(fun, blocks, succs, preds)

    %Function{
      func: func,
      arity: arity,
      entry: entry,
      blocks: structs,
      rpo: rpo,
      idom: idom,
      dom_children: invert_idom(idom),
      ipdom: ipdom,
      loop_headers: loop_headers(succs, entry, idom),
      labels: Map.new(fun.labels, fn {label, idx} -> {label, Map.fetch!(block_of, idx)} end),
      selects: select_tables(fun, block_of)
    }
  end

  defp leaders(fun, n) do
    label_leaders = fun.labels |> Map.values()

    after_terminators =
      for idx <- 0..(n - 1), control_kind(fun, idx) != nil, idx + 1 < n, do: idx + 1

    MapSet.new([0] ++ label_leaders ++ after_terminators)
  end

  defp blocks_from_leaders(leaders, n) do
    sorted = Enum.sort(leaders)

    sorted
    |> Enum.zip(tl(sorted) ++ [n])
    |> Enum.with_index()
    |> Map.new(fn {{first, next}, id} -> {id, {first, next - 1}} end)
  end

  # The control behavior of the instruction at `idx`, or nil for straight-line.
  defp control_kind(fun, idx) do
    op = Map.fetch!(fun.ops, idx)

    cond do
      Map.has_key?(fun.selects, idx) -> :select
      Map.has_key?(fun.jumps, idx) -> :jump
      Map.has_key?(fun.branches, idx) -> :branch
      Map.has_key?(fun.fails, idx) -> :branch
      Map.has_key?(fun.handlers, idx) -> :exception
      op == "return" -> :return
      op == "func_info" -> :raise
      op in @tail_calls -> :tail_call
      op in @raises -> :raise
      true -> nil
    end
  end

  defp successors(fun, last, n, block_of) do
    next = if last + 1 < n, do: [{target_block(block_of, last + 1), :fallthrough}], else: []

    case control_kind(fun, last) do
      :select ->
        for {val, label} <- Map.fetch!(fun.selects, last),
            block = label_block(fun, block_of, label),
            do: {block, select_kind(val)}

      :jump ->
        [{label_block(fun, block_of, Map.fetch!(fun.jumps, last)), :jump}]

      :branch ->
        fail = Map.get(fun.branches, last) || Map.fetch!(fun.fails, last)
        pass = Enum.map(next, fn {block, _} -> {block, :branch_pass} end)
        [{label_block(fun, block_of, fail), :branch_fail} | pass]

      :exception ->
        [{label_block(fun, block_of, Map.fetch!(fun.handlers, last)), :exception} | next]

      kind when kind in [:return, :tail_call, :raise] ->
        []

      nil ->
        next
    end
    |> Enum.reject(fn {block, _kind} -> is_nil(block) end)
  end

  defp select_kind("_fail"), do: :select_fail
  defp select_kind(val), do: {:select_arm, val}

  defp label_block(fun, block_of, label) do
    case Map.get(fun.labels, label) do
      nil -> nil
      idx -> target_block(block_of, idx)
    end
  end

  defp target_block(block_of, idx), do: Map.get(block_of, idx)

  defp entry_block(fun, block_of) do
    with label when label != nil <- fun.entry_label,
         idx when idx != nil <- Map.get(fun.labels, label),
         block when block != nil <- Map.get(block_of, idx) do
      block
    else
      _ -> 0
    end
  end

  defp block_structs(fun, blocks, succs, preds) do
    label_of_first =
      Map.new(fun.labels, fn {label, idx} -> {idx, label} end)

    Map.new(blocks, fn {id, {first, last} = range} ->
      {id,
       %Block{
         id: id,
         range: range,
         label: Map.get(label_of_first, first),
         succs: Enum.sort(Map.get(succs, id, [])),
         preds: Enum.sort(Map.get(preds, id, [])),
         terminator: control_kind(fun, last) || :fallthrough
       }}
    end)
  end

  defp select_tables(fun, block_of) do
    fun.selects
    |> Enum.sort()
    |> Enum.map(fn {idx, rows} ->
      {fails, arms} = Enum.split_with(rows, fn {val, _label} -> val == "_fail" end)

      %{
        idx: idx,
        arms:
          Map.new(arms, fn {val, label} ->
            {val, label_block(fun, block_of, label)}
          end),
        default:
          case fails do
            [{_val, label} | _] -> label_block(fun, block_of, label)
            [] -> nil
          end
      }
    end)
  end

  # --- dominators -------------------------------------------------------------

  # `dfs/4` prepends each node after its successors are done, so the
  # accumulated list is already reverse postorder (entry first).
  defp reverse_postorder(entry, succs) do
    {order, _visited} = dfs(entry, succs, MapSet.new(), [])
    order
  end

  defp dfs(node, succs, visited, order) do
    if MapSet.member?(visited, node) do
      {order, visited}
    else
      visited = MapSet.put(visited, node)

      {order, visited} =
        succs
        |> Map.get(node, [])
        |> Enum.reduce({order, visited}, fn {next, _kind}, {ord, vis} ->
          dfs(next, succs, vis, ord)
        end)

      {[node | order], visited}
    end
  end

  # Iterative Cooper–Harvey–Kennedy. Returns %{block => immediate dominator}
  # for every reachable block except the entry.
  defp dominators(entry, rpo, preds) do
    position = rpo |> Enum.with_index() |> Map.new()
    idom = iterate_dominators(%{entry => entry}, rpo -- [entry], preds, position)
    Map.delete(idom, entry)
  end

  defp iterate_dominators(idom, order, preds, position) do
    {idom, changed?} =
      Enum.reduce(order, {idom, false}, fn block, {acc, changed?} ->
        processed =
          preds
          |> Map.get(block, [])
          |> Enum.map(fn {pred, _kind} -> pred end)
          |> Enum.filter(&Map.has_key?(acc, &1))

        case processed do
          [] ->
            {acc, changed?}

          [first | rest] ->
            new = Enum.reduce(rest, first, &intersect(&1, &2, acc, position))

            if Map.get(acc, block) == new do
              {acc, changed?}
            else
              {Map.put(acc, block, new), true}
            end
        end
      end)

    if changed?, do: iterate_dominators(idom, order, preds, position), else: idom
  end

  defp intersect(b1, b2, idom, position) do
    cond do
      b1 == b2 ->
        b1

      Map.fetch!(position, b1) > Map.fetch!(position, b2) ->
        intersect(idom[b1], b2, idom, position)

      true ->
        intersect(b1, idom[b2], idom, position)
    end
  end

  # Immediate post-dominators: dominators of the reversed CFG, rooted at
  # a virtual :exit that precedes every terminal block (no successors —
  # return, tail call, raise). The same CHK fixpoint runs over the
  # reversed edge maps. Blocks with no path to the exit (genuine
  # infinite loops) have no post-dominator and are absent from the map;
  # a block whose ipdom is the virtual exit maps to `:exit`.
  defp postdominators(succs, preds) do
    terminals = for {id, out} <- succs, out == [], do: id

    succs_rev =
      preds
      |> Map.put(:exit, Enum.map(terminals, &{&1, :virtual}))

    preds_rev =
      terminals
      |> Enum.reduce(succs, fn t, acc ->
        Map.update(acc, t, [{:exit, :virtual}], &[{:exit, :virtual} | &1])
      end)

    rpo_rev = reverse_postorder(:exit, succs_rev)
    dominators(:exit, rpo_rev, preds_rev)
  end

  defp invert_idom(idom) do
    idom
    |> Enum.group_by(fn {_block, dom} -> dom end, fn {block, _dom} -> block end)
    |> Map.new(fn {dom, children} -> {dom, Enum.sort(children)} end)
  end

  # A back edge u -> v is one whose target dominates its source; v is a
  # natural-loop header.
  defp loop_headers(succs, entry, idom) do
    for {from, edges} <- succs,
        {to, _kind} <- edges,
        dominates_via_idom?(idom, entry, to, from),
        into: MapSet.new(),
        do: to
  end

  defp dominates_via_idom?(idom, entry, a, b) do
    cond do
      a == b -> b == entry or Map.has_key?(idom, b)
      not Map.has_key?(idom, b) -> false
      true -> dominates_via_idom?(idom, entry, a, Map.fetch!(idom, b))
    end
  end
end
