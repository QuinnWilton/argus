defmodule Argus.Cfg do
  @moduledoc """
  Basic-block control-flow graphs derived from Layer-1 facts, with dominators
  and loop headers.

  Built per module from the `instruction`/`label_at`/`jump`/`branch`/
  `select_branch`/`next` facts, so the graph is memoized with the module's
  extraction rather than re-derived on every solve: instructions are grouped
  into maximal straight-line blocks (the classic leader algorithm), edges
  carry their kind (`t:Argus.Cfg.Block.edge_kind/0`), and each function gets a
  dominator tree (iterative Cooper–Harvey–Kennedy over reverse postorder) and
  the set of natural-loop headers (back-edge targets).

  The entry block is the one holding the function's *entry label* from
  `function_def` — not instruction 0, which is the `func_info` failure
  landing pad that never falls through.

  Whether an instruction falls through is the emitter's `next` fact, which
  is `Argus.Instr.falls_through?/1`: the graph and every register walk read
  the instruction set one way. So the `raise` BIF, `badrecord` and the
  other raises end their block, and `raw_raise` does not — it is
  `erlang:raise/3`, which returns `badarg` for an invalid class and runs
  the code the compiler put after it.

  Known imprecision, by design: a call to `erlang:raise`/`erlang:error` is an
  ordinary call followed by a (never-taken) fallthrough edge — fail-edge and
  terminator classification is fact-driven, not callee-driven.
  """

  alias Argus.Cfg.{Block, Function}
  alias Argus.Instr
  alias Argus.InstrId

  @doc """
  Build per-function CFGs from typed facts (`Argus.Pipeline.extract/2` with
  `format: :typed`).
  """
  @spec build(Argus.Facts.t()) :: %{{String.t(), non_neg_integer()} => Function.t()}
  def build(facts) when is_map(facts) do
    if Map.get(facts, :instruction, []) != [] and not Map.has_key?(facts, :next) do
      raise ArgumentError,
            "Argus.Cfg.build/1 needs the next relation: it is what says an instruction falls through"
    end

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

    falls =
      facts
      |> Map.get(:next, [])
      |> Enum.reduce(%{}, fn %{from: from}, acc ->
        Map.update(acc, InstrId.fa(from), %{from.idx => true}, &Map.put(&1, from.idx, true))
      end)

    selects =
      facts
      |> Map.get(:select_branch, [])
      |> Enum.group_by(&InstrId.fa(&1.id))
      |> Map.new(fn {fa, rows} ->
        {fa, Enum.group_by(rows, & &1.id.idx, fn row -> {row.val, row.target} end)}
      end)

    # The entry label comes from function_entry, not function_def: it is a
    # positional value and was split out so function_def stays stable under
    # body edits (see Argus.Schema). Keyed by func_id there, so join back
    # through function_def to recover {name, arity}.
    entry_by_func =
      facts
      |> Map.get(:function_entry, [])
      |> Map.new(fn row -> {row.func, row.entry} end)

    entries =
      facts
      |> Map.get(:function_def, [])
      |> Map.new(fn row -> {{row.name, row.arity}, Map.get(entry_by_func, row.func)} end)

    for {fa, ops} <- instrs, into: %{} do
      fun = %{
        ops: ops,
        labels: Map.get(labels, fa, %{}),
        jumps: Map.get(jumps, fa, %{}),
        branches: Map.get(branches, fa, %{}),
        fails: Map.get(fails, fa, %{}),
        handlers: Map.get(handlers, fa, %{}),
        falls: Map.get(falls, fa, %{}),
        selects: Map.get(selects, fa, %{}),
        entry_label: Map.get(entries, fa)
      }

      {fa, build_function(fa, fun)}
    end
  end

  @doc """
  The graph of one function of a module given as disassembly (`%{module:
  ..., functions: ...}`), built from the facts the emitter would produce.
  What an extractor uses when it was handed bare disassembly rather than
  a pipeline module whose graphs are already attached.
  """
  @spec build_for(map(), atom(), arity()) :: Function.t() | nil
  def build_for(%{module: _, functions: _} = data, name, arity) do
    data
    |> Argus.Pipeline.Emit.emit()
    |> Map.take(Argus.Pipeline.typed_relations())
    |> Argus.Facts.decode()
    |> build()
    |> Map.get({Argus.InstrId.name(name), arity})
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
    fun = Map.put(fun, :last, n - 1)

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
    idom = dominators(entry, preds, succs)
    ipdom = postdominators(succs, preds)
    dom_children = invert_idom(idom)
    structs = block_structs(fun, blocks, succs, preds)

    %Function{
      func: func,
      arity: arity,
      entry: entry,
      blocks: structs,
      rpo: rpo,
      idom: idom,
      dom_children: dom_children,
      ipdom: ipdom,
      loop_headers: loop_headers(succs, entry, dom_children),
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
  # An instruction with no `next` row that none of the transfers above
  # names leaves the function: by returning, by a tail call, or by raising
  # (func_info, the raise BIF and the other raises). The last instruction
  # of a function has no `next` row either way, and nothing after it to
  # fall to.
  defp control_kind(fun, idx) do
    op = Map.fetch!(fun.ops, idx)

    cond do
      Map.has_key?(fun.selects, idx) -> :select
      Map.has_key?(fun.jumps, idx) -> :jump
      Map.has_key?(fun.branches, idx) -> :branch
      Map.has_key?(fun.fails, idx) -> :branch
      Map.has_key?(fun.handlers, idx) -> :exception
      op == "return" -> :return
      Instr.tail_call_op?(op) -> :tail_call
      Map.has_key?(fun.falls, idx) or idx == fun.last -> nil
      true -> :raise
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

  # Lengauer–Tarjan (the simple version, with path compression) over the
  # blocks reachable from `entry`. Returns %{block => immediate dominator}
  # for every reachable block except the entry.
  #
  # Cooper–Harvey–Kennedy, which this replaced, walks the tree from each
  # predecessor up to where the paths meet, and a function whose clauses
  # all fail to one landing pad has as many predecessors there as it has
  # clauses, each as deep as its clause: quadratic, and 1.7 s of
  # idna_mapping's graphs. The tree is the same whichever way it is found.
  @doc false
  # The dominator solver, for a graph a caller derives from a function's
  # blocks (`Argus.Cfg.Function.completing_blocks/1`): `preds` and
  # `succs` map a node to `{node, kind}` edges; returns `%{node => idom}`
  # for the nodes `entry` reaches, the entry itself absent.
  @spec dominator_tree(term(), map(), map()) :: %{term() => term()}
  def dominator_tree(entry, preds, succs), do: dominators(entry, preds, succs)

  defp dominators(entry, preds, succs) do
    {order, dfnum, parent} = preorder(entry, succs)
    vertex = List.to_tuple(order)
    [_entry | non_root] = order

    # Reverse preorder: a block's semidominator is the least one met
    # coming down from its reached predecessors; it waits in its
    # semidominator's bucket, which is settled once the walk is back at
    # the parent of the path that holds it.
    {_ancestor, _label, semi, _bucket, idom} =
      non_root
      |> Enum.reverse()
      |> Enum.reduce({%{}, %{}, dfnum, %{}, %{}}, fn w, {ancestor, label, semi, bucket, idom} ->
        {ancestor, label, semi_w} =
          preds
          |> Map.get(w, [])
          |> Enum.reduce({ancestor, label, Map.fetch!(semi, w)}, fn {v, _kind}, acc ->
            {ancestor, label, best} = acc

            if Map.has_key?(dfnum, v) do
              {u, ancestor, label} = eval(v, ancestor, label, semi)
              {ancestor, label, min(best, Map.fetch!(semi, u))}
            else
              acc
            end
          end)

        semi = Map.put(semi, w, semi_w)
        p = Map.fetch!(parent, w)
        bucket = Map.update(bucket, elem(vertex, semi_w), [w], &[w | &1])
        ancestor = Map.put(ancestor, w, p)
        {settle, bucket} = Map.pop(bucket, p, [])

        {ancestor, label, idom} =
          Enum.reduce(settle, {ancestor, label, idom}, fn v, {ancestor, label, idom} ->
            {u, ancestor, label} = eval(v, ancestor, label, semi)
            dom = if Map.fetch!(semi, u) < Map.fetch!(semi, v), do: u, else: p
            {ancestor, label, Map.put(idom, v, dom)}
          end)

        {ancestor, label, semi, bucket, idom}
      end)

    # A block whose semidominator is not its immediate dominator takes
    # the immediate dominator of the block settled in its place, which
    # preorder has already fixed.
    Enum.reduce(non_root, idom, fn w, idom ->
      dom = Map.fetch!(idom, w)

      if dom == elem(vertex, Map.fetch!(semi, w)),
        do: idom,
        else: Map.put(idom, w, Map.fetch!(idom, dom))
    end)
  end

  # Depth-first preorder from `entry`, without recursion (a chain of
  # clauses is as deep as it is long): the blocks in order, each one's
  # number and each one's parent in the walk.
  defp preorder(entry, succs), do: preorder([{entry, nil}], succs, [], %{}, %{})

  defp preorder([], _succs, order, dfnum, parent), do: {Enum.reverse(order), dfnum, parent}

  defp preorder([{node, from} | rest], succs, order, dfnum, parent) do
    if Map.has_key?(dfnum, node) do
      preorder(rest, succs, order, dfnum, parent)
    else
      dfnum = Map.put(dfnum, node, map_size(dfnum))
      parent = if from == nil, do: parent, else: Map.put(parent, node, from)
      next = for {to, _kind} <- Map.get(succs, node, []), do: {to, node}
      preorder(next ++ rest, succs, [node | order], dfnum, parent)
    end
  end

  # The block of least semidominator on the forest path above `v` (`v`
  # itself when it is a root), compressing the path as it goes. A block
  # with no label is its own.
  defp eval(v, ancestor, label, semi) do
    if Map.has_key?(ancestor, v) do
      {ancestor, label} = compress(v, ancestor, label, semi)
      {Map.get(label, v, v), ancestor, label}
    else
      {v, ancestor, label}
    end
  end

  defp compress(v, ancestor, label, semi) do
    a = Map.fetch!(ancestor, v)

    if Map.has_key?(ancestor, a) do
      {ancestor, label} = compress(a, ancestor, label, semi)
      label_a = Map.get(label, a, a)

      label =
        if Map.fetch!(semi, label_a) < Map.fetch!(semi, Map.get(label, v, v)),
          do: Map.put(label, v, label_a),
          else: label

      {Map.put(ancestor, v, Map.fetch!(ancestor, a)), label}
    else
      {ancestor, label}
    end
  end

  # Immediate post-dominators: dominators of the reversed CFG, rooted at
  # a virtual :exit that precedes every terminal block (no successors —
  # return, tail call, raise). The same solver runs over the reversed
  # edge maps. Blocks with no path to the exit (genuine
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

    dominators(:exit, preds_rev, succs_rev)
  end

  defp invert_idom(idom) do
    idom
    |> Enum.group_by(fn {_block, dom} -> dom end, fn {block, _dom} -> block end)
    |> Map.new(fn {dom, children} -> {dom, Enum.sort(children)} end)
  end

  # A back edge u -> v is one whose target dominates its source; v is a
  # natural-loop header. `a` dominates `b` when `b`'s interval in a walk
  # of the dominator tree lies inside `a`'s; a block the entry does not
  # reach has none and dominates nothing, nor is it dominated.
  defp loop_headers(succs, entry, dom_children) do
    intervals = dom_intervals(entry, dom_children)

    for {from, edges} <- succs,
        {to, _kind} <- edges,
        dominates?(intervals, to, from),
        into: MapSet.new(),
        do: to
  end

  defp dominates?(intervals, a, b) do
    with {:ok, {a_in, a_out}} <- Map.fetch(intervals, a),
         {:ok, {b_in, b_out}} <- Map.fetch(intervals, b) do
      a_in <= b_in and b_out <= a_out
    else
      :error -> false
    end
  end

  # %{block => {entered, left}}, numbered by one walk of the dominator
  # tree from the entry — without recursion, since the tree of a chain of
  # clauses is as deep as the chain is long.
  defp dom_intervals(entry, dom_children) do
    dom_intervals([{:enter, entry}], dom_children, 0, %{})
  end

  defp dom_intervals([], _children, _n, acc), do: acc

  defp dom_intervals([{:enter, node} | rest], children, n, acc) do
    visits = for child <- Map.get(children, node, []), do: {:enter, child}
    dom_intervals(visits ++ [{:leave, node, n} | rest], children, n + 1, acc)
  end

  defp dom_intervals([{:leave, node, entered} | rest], children, n, acc) do
    dom_intervals(rest, children, n + 1, Map.put(acc, node, {entered, n}))
  end
end
