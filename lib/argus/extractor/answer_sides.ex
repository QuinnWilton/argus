defmodule Argus.Extractor.AnswerSides do
  @moduledoc """
  The sides of a test of a call's answer, in one function's control-flow
  graph: which edges out of it hold an answer that found what the call
  looked for (a table `:ets.whereis/1` found, a row `:ets.lookup/2`
  returned), and which hold one that found nothing; and the blocks a walk
  reaches from the function's entry, or from given edges, without taking
  others.

  The test is the first instruction on the straight line after the call
  that reads the answer, the answer followed through the registers it is
  copied to. A classifier (`t:classify/0`) says whether an instruction
  tests the answer, and which of its sides finds it present. An answer
  read any other way first (handed to a call, compared in a value)
  decides nothing here, and has no sides.
  """

  alias Argus.Cfg
  alias Argus.Instr

  @typedoc "A side of a test: its pass or fail edge, or every edge but to the labels'."
  @type side :: :branch_pass | :branch_fail | {:not_to, [non_neg_integer()]}

  @typedoc """
  Whether an instruction tests the answer held in the registers, and on
  which side it finds the answer present.
  """
  @type classify :: (term(), [Instr.reg()] -> {:present_on, side()} | :none)

  @typedoc "A control-flow edge, from block to block."
  @type edge :: {term(), term()}

  @doc """
  The edges out of the test of the answer held in `regs` before the
  instruction at `at`, on the side that finds it present (`want`
  `:present`) or absent (`:absent`): `{:ok, edges}`, or `:error` when the
  answer is read some other way first, or lost.
  """
  @spec side_edges(
          Cfg.Function.t(),
          tuple(),
          non_neg_integer(),
          [Instr.reg()],
          :present | :absent,
          classify()
        ) :: {:ok, [edge()]} | :error
  def side_edges(_fun, _table, _at, [], _want, _classify), do: :error

  def side_edges(fun, table, at, regs, want, classify) when at < tuple_size(table) do
    instr = elem(table, at)

    case classify.(instr, regs) do
      {:present_on, side} ->
        block = Cfg.Function.block_at(fun, at)

        {:ok,
         for(
           {to, kind} <- block.succs,
           present_side?(kind, to, side, fun) == (want == :present),
           do: {block.id, to}
         )}

      :none ->
        cond do
          reads_value?(instr, regs) -> :error
          not Instr.falls_through?(instr) -> :error
          true -> side_edges(fun, table, at + 1, carried(instr, regs), want, classify)
        end
    end
  end

  def side_edges(_fun, _table, _at, _regs, _want, _classify), do: :error

  @undefined {:atom, :undefined}

  @doc """
  `t:classify/0` for an answer that is `:undefined` where nothing was
  found (`:ets.whereis/1`, `:ets.info/1,2`): the fail edge of an equality
  test with it, the pass edge of an inequality, every way out of a
  select but to the `:undefined` arm's code.
  """
  @spec undefined_test(term(), [Instr.reg()]) :: {:present_on, side()} | :none
  def undefined_test({:test, op, _fail, args}, regs) when op in [:is_eq_exact, :is_eq] do
    if compares?(args, regs, @undefined), do: {:present_on, :branch_fail}, else: :none
  end

  def undefined_test({:test, op, _fail, args}, regs) when op in [:is_ne_exact, :is_ne] do
    if compares?(args, regs, @undefined), do: {:present_on, :branch_pass}, else: :none
  end

  def undefined_test({:select_val, reg, _fail, {:list, cases}}, regs) do
    labels = for [@undefined, {:f, label}] <- Enum.chunk_every(cases, 2), do: label

    if Instr.register(reg) in regs and labels != [],
      do: {:present_on, {:not_to, labels}},
      else: :none
  end

  def undefined_test(_instr, _regs), do: :none

  defp compares?(args, regs, value) do
    args = Enum.map(args, &Instr.register/1)
    value in args and Enum.any?(args, &(&1 in regs))
  end

  defp present_side?(kind, _to, side, _fun) when is_atom(side), do: kind == side

  defp present_side?(_kind, to, {:not_to, labels}, fun),
    do: not Enum.any?(labels, &(Map.get(fun.labels, &1) == to))

  # The instruction reads a register holding the answer other than to
  # copy it.
  defp reads_value?(instr, regs) do
    uses = Instr.uses(instr)
    defs = Instr.defs(instr)

    Enum.any?(uses, &(&1 in regs)) and
      not Enum.all?(defs, fn dst -> Instr.copy_source(instr, dst) in regs end)
  end

  defp carried(instr, regs) do
    copies =
      for dst <- Instr.defs(instr),
          Instr.copy_source(instr, dst) in regs,
          do: dst

    Enum.uniq(Instr.carry(instr, regs) ++ copies)
  end

  @doc """
  The blocks reached from the entry without taking any of `edges` and
  without going on past an instruction in `stops`, and for each block
  holding one, the first: what lies after it in the block is past it.
  """
  @spec reach_until(Cfg.Function.t(), [edge()], [non_neg_integer()]) ::
          {MapSet.t(), %{term() => non_neg_integer()}}
  def reach_until(fun, edges, stops) do
    avoid = MapSet.new(edges)

    barrier =
      Enum.reduce(stops, %{}, fn idx, acc ->
        case Cfg.Function.block_at(fun, idx) do
          nil -> acc
          block -> Map.update(acc, block.id, idx, &min(&1, idx))
        end
      end)

    {walk_until([fun.entry], fun, avoid, barrier, MapSet.new([fun.entry])), barrier}
  end

  defp walk_until([], _fun, _avoid, _barrier, seen), do: seen

  defp walk_until([id | rest], fun, avoid, barrier, seen) do
    next =
      if Map.has_key?(barrier, id),
        do: [],
        else:
          for(
            {to, _kind} <- Map.fetch!(fun.blocks, id).succs,
            not MapSet.member?(avoid, {id, to}),
            not MapSet.member?(seen, to),
            uniq: true,
            do: to
          )

    walk_until(next ++ rest, fun, avoid, barrier, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  @doc """
  Whether the instruction at `idx` lies in a block of `seen`; an
  instruction in no block is taken as reached.
  """
  @spec reached?(Cfg.Function.t(), MapSet.t(), non_neg_integer()) :: boolean()
  def reached?(fun, seen, idx) do
    case Cfg.Function.block_at(fun, idx) do
      nil -> true
      block -> MapSet.member?(seen, block.id)
    end
  end

  @doc """
  Whether the instruction at `idx` lies outside the blocks `reach_until/3`
  reached, or past the stop that ends its block's walk.
  """
  @spec past?(Cfg.Function.t(), MapSet.t(), %{term() => non_neg_integer()}, non_neg_integer()) ::
          boolean()
  def past?(fun, seen, barrier, idx) do
    case Cfg.Function.block_at(fun, idx) do
      nil ->
        false

      block ->
        not MapSet.member?(seen, block.id) or
          (Map.has_key?(barrier, block.id) and Map.fetch!(barrier, block.id) < idx)
    end
  end
end
