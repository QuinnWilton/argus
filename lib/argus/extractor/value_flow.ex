defmodule Argus.Extractor.ValueFlow do
  @moduledoc """
  Shared dataflow solver for ParamFlow, TermFlow and Dependence.

  Each extractor defines the value written by an instruction and how to join
  values reaching a read. The solver evaluates instructions in order, then
  revisits only those affected by changed writes or explicitly requested by
  the extractor. Changes are detected with `==`.

  Evaluators must be monotone over a finite lattice to reach the same least
  fixpoint regardless of evaluation order. Every changing state dependency
  must reschedule its readers through `also`. Missing writes represent bottom;
  evaluators must not withdraw previously emitted writes.

  The default solves to convergence. An optional evaluation budget raises on
  exhaustion: a partial result must not masquerade as a completed fixpoint.
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

  `:max_evaluations` defaults to `:infinity`. A positive integer bounds
  evaluations per instruction and raises if more work remains at that bound.
  """
  @spec solve([non_neg_integer()], reads(), state, evaluate(state), keyword()) ::
          {outs(), state}
        when state: term()
  def solve(idxs, reads, state, evaluate, opts \\ []) do
    env = %{
      users: users(reads),
      evaluate: evaluate,
      max: Keyword.get(opts, :max_evaluations, :infinity)
    }

    unless env.max == :infinity or (is_integer(env.max) and env.max > 0) do
      raise ArgumentError, "max_evaluations must be a positive integer or :infinity"
    end

    idxs = Enum.uniq(idxs)
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

  @doc "Join reaching sources for a single register without constructing all inputs."
  @spec input(reads(), outs(), non_neg_integer(), String.t(), (non_neg_integer() -> term())) ::
          Enumerable.t()
  def input(reads, outs, idx, reg, param) do
    join(Map.get(Map.get(reads, idx, %{}), reg, []), outs, reg, param)
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

        if env.max != :infinity and evaluated >= env.max do
          raise ArgumentError,
                "value-flow evaluation budget exhausted at instruction #{idx} (#{env.max})"
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
    # Compare only the final write, not intermediate values overwritten in
    # the same evaluation. Otherwise a stable transfer can reschedule forever.
    Enum.reduce(Map.new(writes), {false, outs}, fn {reg, value}, {changed?, outs} ->
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
