defmodule Argus.Pipeline.Derive do
  @moduledoc """
  Base facts derived from one module's control-flow and reaching definitions.

  The pipeline owns scheduling, prepared data and failure reporting. This module
  owns the three derivations: `def_use`, `conditional_call`, and the
  `site_block`/`block_flow` representation read by Datalog ordering rules.
  They reuse `Argus.Instr.Reaching` and `Argus.Cfg` semantics; no separate
  instruction model or whole-program fixpoint is introduced here.
  """

  alias Argus.Cfg
  alias Argus.InstrId

  @doc "Instruction-to-instruction reaching definitions, with deterministic row order."
  @spec def_use(MapSet.t() | nil) :: Argus.Pipeline.Emit.facts()
  def def_use(nil), do: %{}

  # Sorted: `reaching` is a set of terms holding atoms, and a VM iterates
  # a small set in atom-table order, so the same module would otherwise
  # yield its rows in an order that depends on the VM that read it.
  def def_use(reaching) do
    rows =
      for {%InstrId{} = d, _reg, u} <- reaching,
          uniq: true,
          do: [InstrId.format(d), InstrId.format(u)]

    rows = Enum.sort(rows)

    if rows == [], do: %{}, else: %{def_use: rows}
  end

  # Call instructions that do not run on every path through their
  # function that completes — the calls that only happen on some paths.
  # A path that raises is none of them: a clause head failing into
  # func_info (Erlang's `init([]) ->`) or a badmatch decides nothing a
  # caller goes on from (Cfg.Function.completing_blocks/1). A function
  # no path of which completes falls back to control dependence.
  # Positional like def_use (keyed on instruction IDs), and derived here
  # for the same reason: the graphs exist in Argus.Cfg, and the
  # alternative is reconstructing them in Datalog on every solve.
  @doc "Calls absent from some completing path; raising paths do not count as completion."
  @spec conditional_calls(Argus.Pipeline.Emit.facts(), map()) :: Argus.Pipeline.Emit.facts()
  def conditional_calls(base_facts, cfgs) do
    call_ids =
      for relation <- [:local_call, :remote_call, :bif_call],
          [id | _] <- Map.get(base_facts, relation, []),
          do: id

    raising = raising_tail_blocks(base_facts, cfgs)

    conditional_blocks =
      Map.new(cfgs, fn {key, fun} ->
        {key, conditional_blocks(fun, Map.get(raising, key, MapSet.new()))}
      end)

    rows =
      for id <- call_ids,
          {:ok, %InstrId{func: name, arity: arity, idx: idx}} <- [InstrId.parse(id)],
          fun = Map.get(cfgs, {name, arity}),
          fun != nil,
          block = Cfg.Function.block_at(fun, idx),
          block != nil,
          MapSet.member?(conditional_blocks[{name, arity}], block.id),
          do: [id]

    case rows do
      [] -> %{}
      rows -> %{conditional_call: Enum.sort(rows)}
    end
  end

  # The basic block of the instructions a rule asks the order of
  # (site_block), and the flow between the blocks holding one
  # (block_flow): what clientlib/order.dl's runs_after reads. Positional
  # like conditional_call, and derived here for the same reason: the
  # graphs exist in Argus.Cfg, and the alternative is reading
  # `instruction` and `next` in every solve that asks. A block is named
  # by its first instruction. The flow is one trip's
  # (Cfg.Function.forward_succs/2): a loop's back edge would order two
  # instructions of its body both ways.
  #
  # Only what runs_after can answer is emitted, which on ash is a small
  # part of what the graphs hold:
  #
  # - The kinds rules ask about. A call to a named function, local or
  #   remote, is asked of and read (a cancel, a start, a call toward a
  #   helper or handed a fun: call_site's and fun_handed's
  #   instructions); a receive and a branch are read. A BIF instruction
  #   (`bif`, `gc_bif`), a call through a fun or `apply` and a send have
  #   no row: a rule that asks of one adds its relation here.
  # - The sites an order a call or a receive starts takes part in.
  #   runs_after is asked of those only (order.dl: a branch is read, never
  #   asked of), so a site none runs before, and one nothing runs after,
  #   can be in no answer: a function of branches alone has no row.
  # - The flow contracted to the blocks holding a kept site: runs_after
  #   asks only whether one such block reaches another, so a block
  #   holding none is passed through, and an edge joins a kept site's
  #   block to each block holding one that is the next such on a path
  #   from it. Its closure is the graph's, restricted to those blocks.
  @ordered_sites [
    local_call: "call",
    remote_call: "call",
    recv_start: "receive",
    branch: "branch"
  ]

  @doc "Relevant sites and contracted, forward-only block flow for clientlib/order.dl."
  @spec block_order(Argus.Pipeline.Emit.facts(), map()) :: Argus.Pipeline.Emit.facts()
  def block_order(base_facts, cfgs) do
    placed =
      for {relation, kind} <- @ordered_sites,
          [id | _] <- Map.get(base_facts, relation, []),
          {:ok, %InstrId{func: name, arity: arity, idx: idx} = site} <- [InstrId.parse(id)],
          fun = Map.get(cfgs, {name, arity}),
          fun != nil,
          block = Cfg.Function.block_at(fun, idx),
          block != nil,
          do: {site, kind, fun, block}

    kept =
      placed
      |> Enum.group_by(fn {site, _, _, _} -> InstrId.fa(site) end)
      |> Enum.map(fn {_fa, held} -> ordered_from_starts(held) end)
      |> Enum.reject(&(&1 == []))

    sites =
      for held <- kept,
          {site, kind, _fun, block} <- held,
          do: [InstrId.format(site), kind, block_name(site, block), Integer.to_string(site.idx)]

    flows =
      for [{site, _kind, fun, _block} | _] = held <- kept,
          holding = Map.new(held, fn {_, _, _, block} -> {block.id, true} end),
          from <- Map.keys(holding),
          to <- next_holding(fun, holding, Map.fetch!(fun.blocks, from)),
          do: [
            block_name(site, Map.fetch!(fun.blocks, from)),
            block_name(site, Map.fetch!(fun.blocks, to))
          ]

    %{}
    |> put_rows(:site_block, sites)
    |> put_rows(:block_flow, flows)
  end

  # The kinds runs_after is asked of: the instructions an order starts at.
  @starts ["call", "receive"]

  # The sites of one function that take part in an order a start (a call
  # or a receive) begins: each a start runs before (earlier in its block,
  # or in a block the flow reaches it from), and each start a site runs
  # after.
  defp ordered_from_starts([{_, _, fun, _} | _] = held) do
    starts = for {site, kind, _fun, block} <- held, kind in @starts, do: {block.id, site.idx}

    first_start =
      Enum.reduce(starts, %{}, fn {b, i}, acc -> Map.update(acc, b, i, &min(&1, i)) end)

    last_site =
      Enum.reduce(held, %{}, fn {s, _, _, b}, acc ->
        Map.update(acc, b.id, s.idx, &max(&1, s.idx))
      end)

    reached = reached_from(fun, Map.keys(first_start))
    holding = Map.new(held, fn {_, _, _, block} -> {block.id, true} end)

    after_start? = fn {site, _kind, _fun, block} ->
      Map.has_key?(reached, block.id) or Map.get(first_start, block.id, site.idx) < site.idx
    end

    before_site? = fn {site, kind, _fun, block} ->
      kind in @starts and
        (site.idx < Map.fetch!(last_site, block.id) or next_holding(fun, holding, block) != [])
    end

    Enum.filter(held, &(after_start?.(&1) or before_site?.(&1)))
  end

  # The blocks one trip's flow reaches from any of `from`, by one edge or
  # more, as a map of block id to true (a plain map, as Cfg.Function's own
  # walks keep theirs: MapSet is opaque to dialyzer through these clauses).
  defp reached_from(fun, from) do
    succs = Enum.flat_map(from, &Cfg.Function.forward_succs(fun, Map.fetch!(fun.blocks, &1)))
    reach(fun, succs, %{})
  end

  defp reach(_fun, [], seen), do: seen

  defp reach(fun, [id | rest], seen) do
    if Map.has_key?(seen, id) do
      reach(fun, rest, seen)
    else
      succs = Cfg.Function.forward_succs(fun, Map.fetch!(fun.blocks, id))
      reach(fun, succs ++ rest, Map.put(seen, id, true))
    end
  end

  # The blocks of `holding` one trip's flow reaches from `block` through
  # blocks outside it: the first of `holding` on each path.
  defp next_holding(fun, holding, block),
    do: next_holding(fun, holding, Cfg.Function.forward_succs(fun, block), %{}, [])

  defp next_holding(_fun, _holding, [], _seen, found), do: found

  defp next_holding(fun, holding, [id | rest], seen, found) do
    cond do
      Map.has_key?(seen, id) ->
        next_holding(fun, holding, rest, seen, found)

      Map.has_key?(holding, id) ->
        next_holding(fun, holding, rest, Map.put(seen, id, true), [id | found])

      true ->
        succs = Cfg.Function.forward_succs(fun, Map.fetch!(fun.blocks, id))
        next_holding(fun, holding, succs ++ rest, Map.put(seen, id, true), found)
    end
  end

  # A block's name: the ID of its first instruction, in the function of
  # `site`.
  defp block_name(%InstrId{} = site, %Cfg.Block{range: {first, _last}}),
    do: InstrId.format(%{site | idx: first})

  defp put_rows(facts, _relation, []), do: facts

  defp put_rows(facts, relation, rows),
    do: Map.put(facts, relation, rows |> Enum.uniq() |> Enum.sort())

  # The blocks ending in a tail call that raises (`erlang:error/1`,
  # `exit/1`, `throw/1`, `raise/3`): the compiler's badmap and a dot
  # access's error side end so, and a path there completes nothing.
  @raising_bifs ~w(error exit throw raise nif_error)

  defp raising_tail_blocks(base_facts, cfgs) do
    for [id, _func, ":erlang", name, _arity] <- Map.get(base_facts, :remote_call, []),
        name in @raising_bifs,
        {:ok, %InstrId{func: fname, arity: arity, idx: idx}} <- [InstrId.parse(id)],
        fun = Map.get(cfgs, {fname, arity}),
        fun != nil,
        block = Cfg.Function.block_at(fun, idx),
        block != nil,
        block.terminator == :tail_call,
        elem(block.range, 1) == idx,
        reduce: %{} do
      acc -> Map.update(acc, {fname, arity}, MapSet.new([block.id]), &MapSet.put(&1, block.id))
    end
  end

  defp conditional_blocks(fun, raising) do
    case Cfg.Function.completing_blocks(fun, raising) do
      nil ->
        fun |> Cfg.Function.control_deps() |> Map.keys() |> MapSet.new()

      always ->
        for {id, _block} <- fun.blocks, not MapSet.member?(always, id), into: MapSet.new(), do: id
    end
  end
end
