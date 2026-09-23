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
  function many times pay for it once. A different module replaces it.
  """

  alias Argus.Dataflow
  alias Argus.Instr

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
        solution = solve(instrs)
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

  defp solve(instrs) do
    code = List.to_tuple(instrs)
    n = tuple_size(code)
    ids = Enum.to_list(0..(n - 1)//1)

    labels =
      for {{:label, l}, idx} <- Enum.with_index(instrs), into: %{}, do: {l, idx}

    succ =
      Map.new(ids, fn idx ->
        instr = elem(code, idx)
        next = if Instr.falls_through?(instr) and idx + 1 < n, do: [idx + 1], else: []

        jumps =
          for l <- Instr.targets(instr), target = Map.get(labels, l), target != nil, do: target

        {idx, Enum.uniq(next ++ jumps)}
      end)

    defs = Map.new(ids, &{&1, Instr.defs(elem(code, &1))})

    case ids do
      [] ->
        %{code: code, block_of: %{}, blocks: %{}}

      _ ->
        blocks = ids |> Dataflow.block_ins(succ, defs, entry(instrs)) |> Enum.with_index()

        %{
          code: code,
          block_of:
            for(
              {{block, _in}, n} <- blocks,
              {idx, pos} <- Enum.with_index(block),
              into: %{},
              do: {idx, {n, pos}}
            ),
          blocks:
            Map.new(blocks, fn {{block, in_map}, n} -> {n, {List.to_tuple(block), in_map}} end)
        }
    end
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
