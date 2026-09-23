defmodule Argus.Extractor.ValueFlow do
  @moduledoc """
  A value per register write, solved to a fixpoint over one function's
  reaching definitions: the engine `Argus.Extractors.ParamFlow`,
  `Argus.Extractors.PidFlow` and `Argus.Extractors.Dependence` share.

  Each of them asks the same question of a different lattice — which
  parameters a value is made of, which processes it can be, which
  sources it depends on — and each answers it the same way: an
  instruction's writes are a function of what reaches its reads, and
  what reaches a read is the join of what the writes reaching it hold.
  The extractor says what an instruction writes (`evaluate`); this
  module keeps what every write holds, and evaluates an instruction
  again only when a write it reads changes, or when the extractor says
  another of its own facts did (`also`). A function's instructions are
  first evaluated in order, so code without a loop settles in one
  evaluation each.

  The values are the extractor's: a write is changed when the new value
  is not `==` the one held, and a read joins the writes that reach it as
  `inputs/4` does (PidFlow joins its own, the same way). The fixpoint is
  the least one whatever the order of evaluation, as long as every
  `evaluate` is monotone in what it reads — which is what makes the
  worklist here and a pass over every instruction until nothing changes
  the same answer.
  """

  alias Argus.InstrId

  @typedoc "Where a read's value can come from: a parameter, or the write at an instruction."
  @type from :: {:param, non_neg_integer()} | {:def, non_neg_integer()}

  @typedoc "Per instruction, per register it reads (spelled `\"x0\"`), what reaches it."
  @type reads :: %{non_neg_integer() => %{String.t() => [from()]}}

  @typedoc "What each write holds, by instruction and register."
  @type outs :: %{{non_neg_integer(), String.t()} => term()}

  @typedoc """
  What an instruction writes, given what every write holds so far and
  the extractor's own state: the writes in order (a later one to the
  same register wins), the new state, and more instructions to evaluate
  again.
  """
  @type evaluate(state) ::
          (non_neg_integer(), outs(), state ->
             {[{String.t(), term()}], state, [non_neg_integer()]})

  # A fixpoint over a finite lattice converges; the bound only guards a bug.
  @max_evaluations 64

  @doc """
  The reads of every function in a module's reaching definitions
  (`Argus.Dataflow.reaching_uses/2` with `params: true`), keyed by
  function ID.
  """
  @spec reads_by_function(Enumerable.t()) :: %{String.t() => reads()}
  def reads_by_function(reaching) do
    reaching
    |> Enum.reduce(%{}, fn {source, reg, %InstrId{} = use}, acc ->
      from =
        case source do
          {:param, k} -> {:param, k}
          %InstrId{idx: d} -> {:def, d}
        end

      key = {use.module, use.func, use.arity}

      Map.update(acc, key, %{use.idx => %{reg => [from]}}, fn by_idx ->
        Map.update(by_idx, use.idx, %{reg => [from]}, fn regs ->
          Map.update(regs, reg, [from], &[from | &1])
        end)
      end)
    end)
    |> Map.new(fn {{m, f, a}, reads} -> {InstrId.func_id(m, f, a), reads} end)
  end

  @doc """
  Solves one function: evaluates `idxs` in order, then again whichever
  of them a changed write reaches or `evaluate` names, until nothing
  changes. Returns what every write holds and the final state.

  `:max_evaluations` (default #{@max_evaluations}) bounds how often one
  instruction is evaluated.
  """
  @spec solve([non_neg_integer()], reads(), state, evaluate(state), keyword()) ::
          {outs(), state}
        when state: term()
  def solve(idxs, reads, state, evaluate, opts \\ []) do
    env = %{
      users: users(reads),
      evaluate: evaluate,
      max: Keyword.get(opts, :max_evaluations, @max_evaluations)
    }

    run(:queue.from_list(idxs), MapSet.new(idxs), %{}, %{}, state, env)
  end

  @doc """
  What each register instruction `idx` reads may hold there: `%{reg =>
  MapSet}`, the union of the writes that reach the read, with parameter
  `k` as `param.(k)`.
  """
  @spec inputs(reads(), outs(), non_neg_integer(), (non_neg_integer() -> term())) ::
          %{String.t() => MapSet.t()}
  def inputs(reads, outs, idx, param) do
    reads
    |> Map.get(idx, %{})
    |> Map.new(fn {reg, froms} -> {reg, join(froms, outs, reg, param)} end)
  end

  defp join(froms, outs, reg, param) do
    Enum.reduce(froms, MapSet.new(), fn
      {:param, k}, acc -> MapSet.put(acc, param.(k))
      {:def, d}, acc -> MapSet.union(acc, Map.get(outs, {d, reg}, MapSet.new()))
    end)
  end

  # Which instructions read each instruction's writes.
  defp users(reads) do
    Enum.reduce(reads, %{}, fn {use, regs}, acc ->
      Enum.reduce(regs, acc, fn {_reg, froms}, inner ->
        Enum.reduce(froms, inner, fn
          {:def, d}, deep -> Map.update(deep, d, [use], &[use | &1])
          {:param, _k}, deep -> deep
        end)
      end)
    end)
  end

  defp run(queue, pending, outs, count, state, env) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        {outs, state}

      {{:value, idx}, queue} ->
        pending = MapSet.delete(pending, idx)
        evaluated = Map.get(count, idx, 0)

        if evaluated >= env.max do
          run(queue, pending, outs, count, state, env)
        else
          count = Map.put(count, idx, evaluated + 1)
          {writes, state, also} = env.evaluate.(idx, outs, state)
          {changed?, outs} = commit(idx, writes, outs)
          targets = if(changed?, do: Map.get(env.users, idx, []), else: []) ++ also
          {queue, pending} = enqueue(targets, queue, pending)
          run(queue, pending, outs, count, state, env)
        end
    end
  end

  defp commit(idx, writes, outs) do
    Enum.reduce(writes, {false, outs}, fn {reg, value}, {changed?, outs} ->
      if Map.get(outs, {idx, reg}) == value,
        do: {changed?, outs},
        else: {true, Map.put(outs, {idx, reg}, value)}
    end)
  end

  defp enqueue(targets, queue, pending) do
    Enum.reduce(targets, {queue, pending}, fn target, {q, p} ->
      if MapSet.member?(p, target),
        do: {q, p},
        else: {:queue.in(target, q), MapSet.put(p, target)}
    end)
  end
end
