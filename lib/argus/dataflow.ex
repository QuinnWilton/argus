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
  >
  > Every caller does this correctly today (`Planchette.Flow.build/1` and
  > `Gloss.Adapters.dataflow/1` are both per module, as is the derivation in
  > `Argus.Pipeline`), so this documents a precondition that was being met
  > by convention rather than fixing a live defect.
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
    |> Enum.flat_map(fn {block, in_set} -> resolve(block, in_set, defs, uses) end)
    |> MapSet.new()
  end

  @doc false
  # The solver itself, for `Argus.Instr.Reaching`, which runs it over a
  # function's instruction list rather than its facts: one function's
  # straight-line blocks, each with the {source, reg} pairs reaching its
  # start. `ids` in stream order, `succ` the successor lists, `defs` the
  # registers each id writes, `entry` the entry id and what reaches it.
  @spec block_ins([id], %{id => [id]}, %{id => [reg]}, {id, [{term(), reg}]}) ::
          [{[id], MapSet.t({term(), reg})}]
        when id: term(), reg: term()
  def block_ins(ids, succ, defs, {entry_id, seed}) do
    preds = invert(succ)
    blocks = build_blocks(ids, succ, preds, entry_id)
    block_of = for {block, n} <- Enum.with_index(blocks), id <- block, into: %{}, do: {id, n}
    entry = {Map.fetch!(block_of, entry_id), seed}

    block_succs =
      blocks
      |> Enum.with_index()
      |> Map.new(fn {block, n} ->
        targets = succ |> Map.get(List.last(block), []) |> Enum.map(&Map.fetch!(block_of, &1))
        {n, Enum.uniq(targets)}
      end)

    block_preds = invert(block_succs)
    summaries = Map.new(Enum.with_index(blocks), fn {block, n} -> {n, summarize(block, defs)} end)

    out = solve(Map.keys(summaries), block_succs, block_preds, summaries, entry)

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, n} -> {block, block_in(n, block_preds, out, entry)} end)
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

  # A block's transfer summary: gen = the {id, reg} pairs whose definition
  # survives to the block's end; kill = every register the block writes.
  defp summarize(block, defs) do
    last_def =
      Enum.reduce(block, %{}, fn id, acc ->
        Enum.reduce(Map.get(defs, id, []), acc, fn reg, inner -> Map.put(inner, reg, id) end)
      end)

    gen = MapSet.new(last_def, fn {reg, id} -> {id, reg} end)
    {gen, MapSet.new(Map.keys(last_def))}
  end

  # Worklist fixpoint over the block graph: a queue with a pending set, so
  # membership checks and re-enqueues stay constant-time on wide graphs.
  defp solve(block_ids, block_succs, block_preds, summaries, entry) do
    out = Map.new(block_ids, &{&1, MapSet.new()})
    queue = :queue.from_list(block_ids)
    iterate(queue, MapSet.new(block_ids), block_succs, block_preds, summaries, entry, out)
  end

  defp iterate(queue, pending, succs, preds, summaries, entry, out) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        out

      {{:value, n}, queue} ->
        pending = MapSet.delete(pending, n)
        {gen, kill} = Map.fetch!(summaries, n)
        in_set = block_in(n, preds, out, entry)
        surviving = Enum.reject(in_set, fn {_id, reg} -> MapSet.member?(kill, reg) end)
        new_out = MapSet.union(gen, MapSet.new(surviving))

        if MapSet.equal?(new_out, Map.fetch!(out, n)) do
          iterate(queue, pending, succs, preds, summaries, entry, out)
        else
          {queue, pending} = enqueue(Map.get(succs, n, []), queue, pending)
          iterate(queue, pending, succs, preds, summaries, entry, Map.put(out, n, new_out))
        end
    end
  end

  defp enqueue(blocks, queue, pending) do
    Enum.reduce(blocks, {queue, pending}, fn n, {q, p} ->
      if MapSet.member?(p, n) do
        {q, p}
      else
        {:queue.in(n, q), MapSet.put(p, n)}
      end
    end)
  end

  # A block starts from what its predecessors leave behind; the entry
  # block also from the function's parameters (when the caller asked for
  # them), since a loop back to the entry is a predecessor too.
  defp block_in(n, preds, out, {entry_block, seed}) do
    from_preds =
      preds
      |> Map.get(n, [])
      |> Enum.reduce(MapSet.new(), &MapSet.union(&2, Map.fetch!(out, &1)))

    if n == entry_block, do: Enum.into(seed, from_preds), else: from_preds
  end

  # One local walk: each use reads the state before its own instruction's
  # writes; each write then becomes the sole reaching definition of its
  # register for the rest of the block.
  defp resolve(block, in_set, defs, uses) do
    initial =
      Enum.group_by(in_set, fn {_id, reg} -> reg end, fn {id, _reg} -> id end)

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
