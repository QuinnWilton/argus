defmodule Argus.Dataflow do
  @moduledoc """
  Reaching definitions over Layer-1 facts: which instruction's register
  write feeds which instruction's register read.

  For every `use` row, the analysis finds the `def` rows that can have
  produced the value being read — true def→use edges that respect register
  reuse, which simple register-name matching cannot.

  ## Control flow

  The successor relation comes from the control-transfer facts, which
  carry every target `Argus.Instr.targets/1` names: `next` (fallthrough),
  `jump`, `branch` (a test's, a map instruction's or a receive's other
  edge), `select_branch`, the fail label of a `bif_call` and of a
  `bs_start`, and the handler of a `try_start` — the same graph as
  `Argus.Cfg`, with labels resolved through `label_at`.

  The exception edge runs from the `try` (or `catch`) instruction to its
  handler, and that is exact rather than an approximation of "any
  instruction in the protected code may raise": the handler reads only
  `y` registers holding values bound before the `try` (a variable bound
  inside the protected code is unsafe in the handler, in Erlang and in
  Elixir alike), the compiler never reuses a slot that is live into the
  handler, and the VM hands over the exception in `x0`–`x2`, which
  `try_case` (`x0` alone at `catch_end`) writes. So what reaches the
  handler is what reaches the `try`.

  ## Algorithm

  Per function (edges never cross functions): instructions chain into
  maximal straight-line blocks, each block gets a gen/kill summary, the
  summaries propagate over the block graph to a fixpoint (classic iterative
  reaching definitions), and the per-instruction edges fall out of one
  local walk per block. This is observationally identical to the
  per-instruction fixpoint, just proportional to blocks rather than
  instructions.
  """

  use Argus.Purity

  alias Argus.InstrId

  @typedoc "A def→use edge: the writing instruction feeds the reading one."
  @type edge :: {InstrId.t(), InstrId.t()}

  @typedoc "What a read may be fed by: an instruction's write, or the parameter that arrived in the register."
  @type source :: InstrId.t() | {:param, non_neg_integer()}

  @typedoc "A reaching definition with the register it travels in."
  @type reaching_use :: {source(), String.t(), InstrId.t()}

  @doc """
  Compute the def→use edge set from typed facts
  (`Argus.Pipeline.extract/2` with `format: :typed`).

  > #### One module at a time {: .warning}
  >
  > Functions are grouped by `InstrId.fa/1`, which is `{name, arity}` and
  > carries no module. Pass facts for a single module. Over a merged
  > multi-module fact set every `init/1` in the program lands in one group
  > and unrelated control-flow graphs are spliced together, which silently
  > loses real edges and invents others — measured at 25,409 edges instead
  > of 45,319 on one project.
  """
  @spec def_use_edges(Argus.Facts.t()) :: MapSet.t(edge())
  @pure true
  def def_use_edges(facts) when is_map(facts) do
    facts
    |> reaching_uses()
    |> MapSet.new(fn {def_id, _reg, use_id} -> {def_id, use_id} end)
  end

  @doc """
  Reaching definitions with the register they travel in: `{source, reg,
  use}` for every read, where `source` is the writing instruction.

  With `params: true`, a function's parameters are sources too: the
  function's entry starts with `{:param, k}` reaching `xk` for every `k`
  below the arity, so a read of `x1` that no instruction wrote resolves
  to `{:param, 1}` instead of to nothing. That is how head destructuring
  shows up — `%{"name" => name}` is a `get_map_elements` reading `x1`
  with no reaching `def` — and it is what lets a caller ask "is this
  value derived from parameter k" rather than only "which instruction
  wrote it". Only the entry is seeded: the entry label from
  `function_entry`, else the instruction after `func_info`, else the
  first instruction. A block nothing else reaches — unreachable code —
  starts from nothing, since whatever `xk` holds there is not the
  parameter.

  Same precondition as `def_use_edges/1`: one module at a time.
  """
  @spec reaching_uses(Argus.Facts.t(), params: boolean()) :: MapSet.t(reaching_use())
  @pure true
  def reaching_uses(facts, opts \\ []) when is_map(facts) do
    params? = Keyword.get(opts, :params, false)
    defs = regs_by_instr(Map.get(facts, :def, []))
    uses = regs_by_instr(Map.get(facts, :use, []))
    succs = successors(facts)
    entries = entries(facts)

    facts
    |> Map.get(:instruction, [])
    |> Enum.group_by(&InstrId.fa(&1.id), &{&1.id, &1.op})
    |> Enum.map(fn {{_name, arity} = fa, rows} ->
      rows = Enum.sort_by(rows, fn {id, _op} -> id.idx end)
      ids = Enum.map(rows, &elem(&1, 0))
      seed = if params?, do: param_sources(arity), else: []
      entry = {entry_id(rows, Map.get(entries, fa)), seed}
      function_edges(ids, Map.get(succs, fa, %{}), defs, uses, entry)
    end)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  # %{fa => entry instruction id}, from function_entry's label.
  defp entries(facts) do
    labels =
      facts
      |> Map.get(:label_at, [])
      |> Map.new(fn %{label: label, id: id} -> {{InstrId.fa(id), label}, id} end)

    for %{func: func, entry: label} <- Map.get(facts, :function_entry, []),
        {:ok, %{func: name, arity: arity}} <- [InstrId.parse_func(func)],
        id = Map.get(labels, {{name, arity}, label}),
        id != nil,
        into: %{},
        do: {{name, arity}, id}
  end

  # Facts without function_entry (built by hand, or from an older
  # emitter) still have func_info, which the entry label follows.
  defp entry_id(_rows, id) when id != nil, do: id

  defp entry_id(rows, nil) do
    case Enum.drop_while(rows, fn {_id, op} -> op != "func_info" end) do
      [_func_info, {id, _op} | _] -> id
      _ -> rows |> List.first() |> elem(0)
    end
  end

  # Parameter k arrives in xk. The pseudo-definition carries no instruction,
  # so a kill by a real write to xk removes it exactly like any other def.
  defp param_sources(arity) do
    Enum.map(0..(arity - 1)//1, fn k -> {{:param, k}, "x#{k}"} end)
  end

  # --- fact wrangling --------------------------------------------------------

  defp regs_by_instr(rows) do
    Enum.reduce(rows, %{}, fn %{id: id, reg: reg}, acc ->
      Map.update(acc, id, [reg], &[reg | &1])
    end)
  end

  # Instruction-level successor edges, grouped per function:
  # %{fa => %{id => [id]}} (target lists deduplicated).
  defp successors(facts) do
    label_to_id =
      facts
      |> Map.get(:label_at, [])
      |> Enum.group_by(&InstrId.fa(&1.id))
      |> Map.new(fn {fa, rows} ->
        {fa, Map.new(rows, fn %{label: label, id: id} -> {label, id} end)}
      end)

    edges =
      Enum.map(Map.get(facts, :next, []), fn %{from: from, to: to} -> {from, to} end) ++
        label_edges(facts, :jump, label_to_id, & &1.target) ++
        label_edges(facts, :branch, label_to_id, & &1.fail) ++
        label_edges(facts, :select_branch, label_to_id, & &1.target) ++
        label_edges(facts, :bif_call, label_to_id, & &1.fail) ++
        label_edges(facts, :bs_start, label_to_id, & &1.fail) ++
        label_edges(facts, :try_start, label_to_id, & &1.handler)

    edges
    |> Enum.group_by(fn {from, _to} -> InstrId.fa(from) end)
    |> Map.new(fn {fa, fa_edges} ->
      succ =
        fa_edges
        |> Enum.group_by(fn {from, _to} -> from end, fn {_from, to} -> to end)
        |> Map.new(fn {from, tos} -> {from, Enum.uniq(tos)} end)

      {fa, succ}
    end)
  end

  # Rows whose target is a label: resolve within the row's own function;
  # unresolvable labels (0, or stripped) produce no edge.
  defp label_edges(facts, relation, label_to_id, target_of) do
    for row <- Map.get(facts, relation, []),
        target = Map.get(Map.get(label_to_id, InstrId.fa(row.id), %{}), target_of.(row)),
        target != nil,
        do: {row.id, target}
  end

  # --- per-function analysis -------------------------------------------------

  defp function_edges(ids, succ, defs, uses, entry) do
    ids
    |> block_ins(succ, defs, entry)
    |> Enum.flat_map(fn {block, in_map} -> resolve(block, in_map, defs, uses) end)
    |> MapSet.new()
  end

  @doc false
  # The solver itself, for `Argus.Instr.Reaching`, which runs it over a
  # function's instruction list rather than its facts: one function's
  # straight-line blocks, each with what reaches its start as `%{reg =>
  # MapSet(source)}`. `ids` in stream order, `succ` the successor lists,
  # `defs` the registers each id writes, `entry` the entry id and the
  # `{source, reg}` pairs that reach it.
  @spec block_ins([id], %{id => [id]}, %{id => [reg]}, {id, [{term(), reg}]}) ::
          [{[id], %{reg => MapSet.t(term())}}]
        when id: term(), reg: term()
  def block_ins(ids, succ, defs, {entry_id, seed}) do
    preds = invert(succ)
    blocks = build_blocks(ids, succ, preds, entry_id)
    block_of = for {block, n} <- Enum.with_index(blocks), id <- block, into: %{}, do: {id, n}

    seed =
      Enum.reduce(seed, %{}, fn {source, reg}, acc ->
        Map.update(acc, reg, MapSet.new([source]), &MapSet.put(&1, source))
      end)

    entry = {Map.fetch!(block_of, entry_id), seed}

    block_succs =
      blocks
      |> Enum.with_index()
      |> Map.new(fn {block, n} ->
        targets = succ |> Map.get(List.last(block), []) |> Enum.map(&Map.fetch!(block_of, &1))
        {n, Enum.uniq(targets)}
      end)

    block_preds = invert(block_succs)
    gens = Map.new(Enum.with_index(blocks), fn {block, n} -> {n, summarize(block, defs)} end)

    ins = solve(Map.keys(gens), block_succs, block_preds, gens, entry)

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, n} -> {block, Map.fetch!(ins, n)} end)
  end

  # Maximal straight-line chains: extend a block while the last instruction's
  # sole successor has that instruction as its sole predecessor (and isn't
  # already placed — a back edge to an earlier block start ends the chain).
  # Walking ids in stream order and starting a block at every unplaced
  # instruction covers unreachable code too, exactly like the
  # per-instruction fixpoint did. The entry always starts a block, so the
  # parameters are seeded where the function begins and nowhere earlier.
  defp build_blocks(ids, succ, preds, entry_id) do
    {blocks, _placed} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {blocks, placed} ->
        if MapSet.member?(placed, id) do
          {blocks, placed}
        else
          block = chain(id, succ, preds, entry_id, MapSet.put(placed, id), [id])
          {[block | blocks], MapSet.union(placed, MapSet.new(block))}
        end
      end)

    Enum.reverse(blocks)
  end

  defp chain(last, succ, preds, entry_id, placed, acc) do
    with [next] <- Map.get(succ, last, []),
         [^last] <- Map.get(preds, next, []),
         true <- next != entry_id,
         false <- MapSet.member?(placed, next) do
      chain(next, succ, preds, entry_id, MapSet.put(placed, next), [next | acc])
    else
      _ -> Enum.reverse(acc)
    end
  end

  # A block's transfer: the last write of each register it writes, as
  # `%{reg => MapSet([id])}`. Every register the block kills is one it
  # generates, so what leaves the block is what reached it with these
  # entries replaced.
  defp summarize(block, defs) do
    block
    |> Enum.reduce(%{}, fn id, acc ->
      Enum.reduce(Map.get(defs, id, []), acc, fn reg, inner -> Map.put(inner, reg, id) end)
    end)
    |> Map.new(fn {reg, id} -> {reg, MapSet.new([id])} end)
  end

  # Worklist fixpoint over the block graph, taking the pending block that
  # comes first in reverse postorder from the entry (unreachable blocks
  # after, in stream order). A block is then visited after every
  # predecessor that is not a back edge, so an acyclic stretch settles in
  # one visit per block; a queue in the map's order visited a join once
  # per predecessor that changed before it.
  #
  # What reaches a point is kept per register, and a register a block
  # does not write leaves it as the very term that entered: at a join of
  # many arms (a table of clauses, a hex encoder) most registers arrive
  # as one shared set from every arm, and the union is a pointer
  # comparison instead of a merge of every `{source, reg}` pair.
  #
  # Returns what reaches each block's start: every block is visited at
  # least once and again whenever a predecessor's output changes, so the
  # last input computed for it is the fixpoint's.
  defp solve(block_ids, block_succs, block_preds, gens, {entry_block, _seed} = entry) do
    rank = rank(entry_block, block_ids, block_succs)
    pending = :gb_sets.from_list(Enum.map(block_ids, &{Map.fetch!(rank, &1), &1}))
    iterate(pending, rank, block_succs, block_preds, gens, entry, %{}, %{})
  end

  defp iterate(pending, rank, succs, preds, gens, entry, ins, outs) do
    if :gb_sets.is_empty(pending) do
      ins
    else
      {{_rank, n}, pending} = :gb_sets.take_smallest(pending)
      in_map = block_in(n, preds, outs, entry)
      ins = Map.put(ins, n, in_map)
      new_out = Map.merge(in_map, Map.fetch!(gens, n))

      if Map.fetch(outs, n) == {:ok, new_out} do
        iterate(pending, rank, succs, preds, gens, entry, ins, outs)
      else
        pending =
          succs
          |> Map.get(n, [])
          |> Enum.reduce(pending, &:gb_sets.add_element({Map.fetch!(rank, &1), &1}, &2))

        iterate(pending, rank, succs, preds, gens, entry, ins, Map.put(outs, n, new_out))
      end
    end
  end

  # %{block => its position}: reverse postorder from the entry, then the
  # blocks no path from the entry reaches, in stream order.
  defp rank(entry_block, block_ids, succs) do
    reachable =
      postorder(
        [{entry_block, Map.get(succs, entry_block, [])}],
        MapSet.new([entry_block]),
        succs,
        []
      )

    seen = MapSet.new(reachable)
    rest = block_ids |> Enum.reject(&MapSet.member?(seen, &1)) |> Enum.sort()
    (reachable ++ rest) |> Enum.with_index() |> Map.new()
  end

  # Iterative depth-first search; the accumulated list is reverse
  # postorder, since a node is prepended once its successors are done.
  defp postorder([], _visited, _succs, order), do: order

  defp postorder([{node, []} | stack], visited, succs, order),
    do: postorder(stack, visited, succs, [node | order])

  defp postorder([{node, [next | rest]} | stack], visited, succs, order) do
    if MapSet.member?(visited, next) do
      postorder([{node, rest} | stack], visited, succs, order)
    else
      stack = [{next, Map.get(succs, next, [])}, {node, rest} | stack]
      postorder(stack, MapSet.put(visited, next), succs, order)
    end
  end

  # A block starts from what its predecessors leave behind; the entry
  # block also from the function's parameters (when the caller asked for
  # them), since a loop back to the entry is a predecessor too. A
  # predecessor not visited yet leaves nothing behind.
  defp block_in(n, preds, out, {entry_block, seed}) do
    start = if n == entry_block, do: seed, else: %{}

    preds
    |> Map.get(n, [])
    |> Enum.reduce(start, fn pred, acc ->
      case Map.fetch(out, pred) do
        {:ok, pred_out} -> join(acc, pred_out)
        :error -> acc
      end
    end)
  end

  defp join(left, right) when map_size(left) == 0, do: right

  defp join(left, right) do
    Map.merge(left, right, fn _reg, a, b -> if a == b, do: a, else: MapSet.union(a, b) end)
  end

  # One local walk: each use reads the state before its own instruction's
  # writes; each write then becomes the sole reaching definition of its
  # register for the rest of the block.
  defp resolve(block, in_map, defs, uses) do
    initial = Map.new(in_map, fn {reg, sources} -> {reg, MapSet.to_list(sources)} end)

    {edges, _state} =
      Enum.reduce(block, {[], initial}, fn id, {edges, state} ->
        new_edges =
          for reg <- Map.get(uses, id, []),
              source <- Map.get(state, reg, []),
              do: {source, reg, id}

        state =
          Enum.reduce(Map.get(defs, id, []), state, fn reg, acc -> Map.put(acc, reg, [id]) end)

        {new_edges ++ edges, state}
      end)

    edges
  end

  defp invert(succ) do
    succ
    |> Enum.flat_map(fn {from, tos} -> Enum.map(tos, &{&1, from}) end)
    |> Enum.group_by(fn {to, _from} -> to end, fn {_to, from} -> from end)
    |> Map.new(fn {to, froms} -> {to, Enum.uniq(froms)} end)
  end
end
