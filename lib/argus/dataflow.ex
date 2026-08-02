defmodule Argus.Dataflow do
  @moduledoc """
  Reaching definitions over Layer-1 facts: which instruction's register
  write feeds which instruction's register read.

  For every `use` row, the analysis finds the `def` rows that can have
  produced the value being read — true def→use edges that respect register
  reuse, which simple register-name matching cannot.

  ## Control flow

  The successor relation comes from the explicit control-transfer facts:
  `next` (fallthrough), `jump`, `branch` (the fail edge), and
  `select_branch`, with labels resolved through `label_at`. This is
  deliberately *not* `Argus.Cfg`'s block-edge relation:

    * Exception edges (`try_start` handlers) are not followed. At the
      handler the VM materializes the exception class/reason/stacktrace in
      `x0`–`x2` without any `def` fact, so following the edge would
      attribute pre-`try` writes of those registers to handler reads — a
      false flow. Handler code instead flows from its own writes (its
      reads of the VM-materialized registers resolve to nothing, honestly).
    * `bif_call`/`bs_start` fail edges are not followed; like the generic
      `branch` fallthrough, the fail path is reached through the facts
      that carry it explicitly.

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

  @doc """
  Compute the def→use edge set from typed facts
  (`Argus.Pipeline.extract/2` with `format: :typed`).
  """
  @spec def_use_edges(Argus.Facts.t()) :: MapSet.t(edge())
  @pure true
  def def_use_edges(facts) when is_map(facts) do
    defs = regs_by_instr(Map.get(facts, :def, []))
    uses = regs_by_instr(Map.get(facts, :use, []))
    succs = successors(facts)

    facts
    |> Map.get(:instruction, [])
    |> Enum.group_by(&InstrId.fa(&1.id), & &1.id)
    |> Enum.map(fn {fa, ids} ->
      function_edges(Enum.sort_by(ids, & &1.idx), Map.get(succs, fa, %{}), defs, uses)
    end)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
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
        label_edges(facts, :select_branch, label_to_id, & &1.target)

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

  defp function_edges(ids, succ, defs, uses) do
    preds = invert(succ)
    blocks = build_blocks(ids, succ, preds)
    block_of = for {block, n} <- Enum.with_index(blocks), id <- block, into: %{}, do: {id, n}

    block_succs =
      blocks
      |> Enum.with_index()
      |> Map.new(fn {block, n} ->
        targets = succ |> Map.get(List.last(block), []) |> Enum.map(&Map.fetch!(block_of, &1))
        {n, Enum.uniq(targets)}
      end)

    block_preds = invert(block_succs)
    summaries = Map.new(Enum.with_index(blocks), fn {block, n} -> {n, summarize(block, defs)} end)

    out = solve(Map.keys(summaries), block_succs, block_preds, summaries)

    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, n} ->
      in_set = block_in(n, block_preds, out)
      resolve(block, in_set, defs, uses)
    end)
    |> MapSet.new()
  end

  # Maximal straight-line chains: extend a block while the last instruction's
  # sole successor has that instruction as its sole predecessor (and isn't
  # already placed — a back edge to an earlier block start ends the chain).
  # Walking ids in stream order and starting a block at every unplaced
  # instruction covers unreachable code too, exactly like the
  # per-instruction fixpoint did.
  defp build_blocks(ids, succ, preds) do
    {blocks, _placed} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {blocks, placed} ->
        if MapSet.member?(placed, id) do
          {blocks, placed}
        else
          block = chain(id, succ, preds, MapSet.put(placed, id), [id])
          {[block | blocks], MapSet.union(placed, MapSet.new(block))}
        end
      end)

    Enum.reverse(blocks)
  end

  defp chain(last, succ, preds, placed, acc) do
    with [next] <- Map.get(succ, last, []),
         [^last] <- Map.get(preds, next, []),
         false <- MapSet.member?(placed, next) do
      chain(next, succ, preds, MapSet.put(placed, next), [next | acc])
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
  defp solve(block_ids, block_succs, block_preds, summaries) do
    out = Map.new(block_ids, &{&1, MapSet.new()})
    queue = :queue.from_list(block_ids)
    iterate(queue, MapSet.new(block_ids), block_succs, block_preds, summaries, out)
  end

  defp iterate(queue, pending, succs, preds, summaries, out) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        out

      {{:value, n}, queue} ->
        pending = MapSet.delete(pending, n)
        {gen, kill} = Map.fetch!(summaries, n)
        in_set = block_in(n, preds, out)
        surviving = Enum.reject(in_set, fn {_id, reg} -> MapSet.member?(kill, reg) end)
        new_out = MapSet.union(gen, MapSet.new(surviving))

        if MapSet.equal?(new_out, Map.fetch!(out, n)) do
          iterate(queue, pending, succs, preds, summaries, out)
        else
          {queue, pending} = enqueue(Map.get(succs, n, []), queue, pending)
          iterate(queue, pending, succs, preds, summaries, Map.put(out, n, new_out))
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

  defp block_in(n, preds, out) do
    preds
    |> Map.get(n, [])
    |> Enum.reduce(MapSet.new(), fn p, acc -> MapSet.union(acc, Map.fetch!(out, p)) end)
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
              def_id <- Map.get(state, reg, []),
              do: {def_id, id}

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
