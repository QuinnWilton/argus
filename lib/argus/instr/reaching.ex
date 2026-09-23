defmodule Argus.Instr.Reaching do
  @moduledoc """
  Reaching definitions over one function's instruction list: which
  instructions' writes can be the value a register holds at a point.

  This is what the extractors' register walks stand on. A walk that
  steps backwards through the instruction stream reads the instruction
  laid out before a label as its predecessor, which it seldom is — the
  code before a label is another clause, or an arm that jumped away —
  and misses writes it has no clause for; either way it answers with a
  value from another path. Reaching definitions follow the real edges
  (`Argus.Instr.targets/1` and fall-through), know every write
  (`Argus.Instr.defs/1`), and say when several writes can reach, which
  a walk then either agrees across or gives up on.

  The solver is `Argus.Dataflow`'s, run over instruction indexes instead
  of facts, so `sources/3` agrees with `Argus.Dataflow.reaching_uses/2`
  on every read the facts record; the test suite checks that on real
  modules. The parameters reach from the entry (the instruction after
  `func_info`) as `{:param, k}` in `xk`.

  Each function's solution is computed once and kept in the process
  dictionary for the module being read, so the walks that query one
  function many times pay for it once, and the emitter's normalized list
  and the extractors' raw one share it. A different module replaces it.
  `uses/2` reads a whole module's reaching definitions off the same
  solutions: the pipeline's `module_data.reaching`.
  """

  alias Argus.Dataflow
  alias Argus.Instr
  alias Argus.InstrId

  @typedoc "What can have written a register: an instruction's index, or a parameter."
  @type source :: non_neg_integer() | {:param, non_neg_integer()}

  @cache :argus_instr_reaching

  @doc """
  What can have written `register` when control reaches instruction
  `idx` (before `idx` runs): instruction indexes and parameters, sorted,
  or `[]` when nothing can — unreachable code, a register no path
  writes, or an `x` register a call on the way destroyed. An `idx` one
  past the last instruction asks what the last one leaves behind, when
  control goes on past it.
  """
  @spec sources([Instr.instr()], non_neg_integer(), term()) :: [source()]
  def sources(instrs, idx, register) do
    reg = Instr.register(register)
    %{code: code, block_of: block_of, blocks: blocks} = solution(instrs)

    # Past the end is where the last instruction goes on to, if it does.
    {at, from} =
      cond do
        idx < tuple_size(code) ->
          {idx, 1}

        idx > 0 and idx == tuple_size(code) and Instr.falls_through?(elem(code, idx - 1)) ->
          {idx - 1, 0}

        true ->
          {nil, 0}
      end

    case Map.fetch(block_of, at) do
      {:ok, {n, pos}} ->
        {block, in_regs} = Map.fetch!(blocks, n)
        walk_back(code, block, pos - from, reg, in_regs)

      :error ->
        []
    end
  end

  @doc """
  The instruction at `idx`, from the solution `sources/3` keeps: constant
  time, where `Enum.at/2` on the list walks it.
  """
  @spec at([Instr.instr()], non_neg_integer()) :: Instr.instr()
  def at(instrs, idx), do: elem(solution(instrs).code, idx)

  @doc """
  Every read in `module`'s functions with the writes that reach it:
  `Argus.Dataflow.reaching_uses/2` with `params: true` over the module's
  facts, computed from the instruction lists and the solutions
  `sources/3` keeps — so a module's reaching definitions are solved once,
  for the pipeline and for every walk that asks afterwards. Registers are
  spelled as the `use` facts spell them (`"x0"`).
  """
  @spec uses(module(), [{:function, atom(), arity(), term(), [Instr.instr()]}]) ::
          MapSet.t(Dataflow.reaching_use())
  def uses(module, functions) do
    functions
    |> Enum.flat_map(fn {:function, name, arity, _entry, instrs} ->
      {:ok, at} = InstrId.parse(InstrId.mint(InstrId.func_id(module, name, arity), 0))
      function_uses(instrs, at)
    end)
    |> MapSet.new()
  end

  # One forward walk per block: each read takes what reaches it before
  # its own instruction's writes; each write is then the one reaching
  # its register for the rest of the block.
  defp function_uses([], _at), do: []

  defp function_uses(instrs, at) do
    %{code: code, blocks: blocks} = solution(instrs)
    ids = %{}

    {edges, _ids} =
      Enum.reduce(blocks, {[], ids}, fn {_n, {block, in_map}}, {edges, ids} ->
        state = Map.new(in_map, fn {reg, sources} -> {reg, MapSet.to_list(sources)} end)

        {edges, _state, ids} =
          block
          |> Tuple.to_list()
          |> Enum.reduce({edges, state, ids}, fn idx, {edges, state, ids} ->
            instr = elem(code, idx)
            {use_id, ids} = instr_id(ids, at, idx)

            {edges, ids} =
              for reg <- Instr.uses(instr),
                  source <- Map.get(state, reg, []),
                  reduce: {edges, ids} do
                {acc, ids} ->
                  {source_id, ids} = source_id(ids, at, source)
                  {[{source_id, spell(reg), use_id} | acc], ids}
              end

            state = Enum.reduce(Instr.defs(instr), state, &Map.put(&2, &1, [idx]))
            {edges, state, ids}
          end)

        {edges, ids}
      end)

    edges
  end

  defp source_id(ids, _at, {:param, _k} = param), do: {param, ids}
  defp source_id(ids, at, idx), do: instr_id(ids, at, idx)

  # One struct per instruction, shared by every edge naming it.
  defp instr_id(ids, at, idx) do
    case Map.fetch(ids, idx) do
      {:ok, id} ->
        {id, ids}

      :error ->
        id = %{at | idx: idx}
        {id, Map.put(ids, idx, id)}
    end
  end

  defp spell({:x, n}), do: "x" <> Integer.to_string(n)
  defp spell({:y, n}), do: "y" <> Integer.to_string(n)
  defp spell({:fr, n}), do: "fr" <> Integer.to_string(n)

  # Within the block the last write before `idx` is the only one; past
  # its start, whatever reaches the block. A block is a chain of
  # instructions each the sole successor of the last, which a jump can
  # join, so it is walked by position rather than by index.
  defp walk_back(_code, _block, pos, reg, in_regs) when pos < 0 do
    case Map.fetch(in_regs, reg) do
      {:ok, sources} -> sources |> MapSet.to_list() |> Enum.sort()
      :error -> []
    end
  end

  defp walk_back(code, block, pos, reg, in_regs) do
    at = elem(block, pos)
    instr = elem(code, at)

    cond do
      Instr.defines?(instr, reg) -> [at]
      Instr.clobbers?(instr, reg) -> []
      true -> walk_back(code, block, pos - 1, reg, in_regs)
    end
  end

  # --- the per-function solution -----------------------------------------

  defp solution(instrs) do
    {module, key} = cache_key(instrs)

    functions =
      case Process.get(@cache) do
        {^module, functions} -> functions
        _other -> %{}
      end

    cached = Map.get(functions, key, [])

    case List.keyfind(cached, instrs, 0) do
      {^instrs, solution} ->
        solution

      nil ->
        solution = solve(instrs, cached)
        kept = Enum.take([{instrs, solution} | cached], 2)
        Process.put(@cache, {module, Map.put(functions, key, kept)})
        solution
    end
  end

  # A function is named by its func_info; code without one (a fragment
  # a caller built) by its hash. The instruction list itself is kept and
  # compared on a hit, so two versions of one function never share an
  # answer — the comparison is a pointer check for the list cached. Two
  # are kept per function: the emitter walks the normalized list, the
  # extractors the raw one.
  defp cache_key(instrs) do
    case Enum.find(instrs, &match?({:func_info, _, _, _}, &1)) do
      {:func_info, module, _name, _arity} = func_info -> {module, func_info}
      nil -> {nil, :erlang.phash2(instrs)}
    end
  end

  # The solution depends on the instructions only through what each
  # writes, where control goes after it and which labels it defines: the
  # skeleton. The emitter's normalized list and the extractors' raw one
  # have the same skeleton (typed registers and allocation hints are not
  # registers), so the second one met borrows the first one's blocks and
  # keeps only its own instructions.
  defp solve(instrs, cached) do
    code = List.to_tuple(instrs)
    skeleton = skeleton(instrs)

    case Enum.find(cached, fn {_instrs, solution} -> solution.skeleton == skeleton end) do
      {_twin, solution} ->
        %{solution | code: code}

      nil ->
        skeleton |> blocks(code, entry(instrs)) |> Map.merge(%{code: code, skeleton: skeleton})
    end
  end

  defp skeleton(instrs) do
    Enum.map(instrs, fn instr ->
      label = with {:label, l} <- instr, do: l, else: (_ -> nil)
      {Instr.defs(instr), Instr.targets(instr), Instr.falls_through?(instr), label}
    end)
  end

  defp blocks([], _code, _entry), do: %{block_of: %{}, blocks: %{}}

  defp blocks(skeleton, code, entry) do
    n = tuple_size(code)
    ids = Enum.to_list(0..(n - 1)//1)
    indexed = Enum.with_index(skeleton)

    labels =
      for {{_defs, _targets, _next?, l}, idx} <- indexed, l != nil, into: %{}, do: {l, idx}

    succ =
      Map.new(indexed, fn {{_defs, targets, next?, _l}, idx} ->
        next = if next? and idx + 1 < n, do: [idx + 1], else: []
        jumps = for l <- targets, target = Map.get(labels, l), target != nil, do: target
        {idx, Enum.uniq(next ++ jumps)}
      end)

    defs = Map.new(indexed, fn {{defs, _targets, _next?, _l}, idx} -> {idx, defs} end)
    blocks = ids |> Dataflow.block_ins(succ, defs, entry) |> Enum.with_index()

    %{
      block_of:
        for(
          {{block, _in}, n} <- blocks,
          {idx, pos} <- Enum.with_index(block),
          into: %{},
          do: {idx, {n, pos}}
        ),
      blocks: Map.new(blocks, fn {{block, in_map}, n} -> {n, {List.to_tuple(block), in_map}} end)
    }
  end

  # The entry is the instruction after func_info, where the parameters
  # arrive; a fragment without one starts at its first instruction and
  # has no parameters.
  defp entry(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil ->
        {0, []}

      at when at + 1 < length(instrs) ->
        {:func_info, _module, _name, arity} = Enum.at(instrs, at)
        {at + 1, Enum.map(0..(arity - 1)//1, &{{:param, &1}, {:x, &1}})}

      _last ->
        {0, []}
    end
  end
end
