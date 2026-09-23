defmodule Argus.Extractors.Dependence do
  @moduledoc """
  What each call, shared-state operation and return value depends on.

  A check-then-act race is a read of shared state whose result decides,
  or is written back by, a later write of the same thing. Inside one
  function that is a question about the function's instructions; across
  functions it is a chain of per-function summaries, which this extractor
  emits and `clientlib/check_then_act.dl` composes.

  A value *depends on* a source when it is computed from it (data), or
  when the instruction computing it runs only because of a test on a value
  that depends on it (control: `Argus.Cfg.Function.control_deps/1`,
  followed transitively). The control half is what makes the `1` in
  `nref = case :mnesia.dirty_read(k) do [] -> 1; [r] -> r.n + 1 end`
  depend on the read although it is a literal.

  Each function is solved on `Argus.Extractor.ValueFlow`; a decision is
  one more value there, and the instructions of the blocks it decides
  are evaluated again when it changes.

  ## Sources

  - `param` — the function's parameter; the source is its position.
  - `call` — the result of a call; the source is the callee's function
    ID. A local helper's own `returns_depends` says what that result
    carries, so the rules compose it per call.
  - `site` — the result of a shared-state operation (`site?/1`); the
    source is its instruction ID, because a finding anchors there.

  ## Emitted facts

  - `site_depends(site, func, kind, source)` — a shared-state operation
    runs only because of the source, or is handed a value made from it.
  - `call_decided(caller, callee, kind, source)` — some call to `callee`
    runs only because of a test on the source. Building a closure counts
    as a call to it.
  - `call_arg_depends(caller, callee, arg_pos, kind, source)` — at some
    call to `callee`, the argument depends on the source. A closure's
    captured variable in environment slot `i` is its parameter
    `arity - env_len + i`, as in `Argus.Extractors.ParamFlow`.
  - `returns_depends(func, kind, source)` — what the function returns
    depends on the source.
  - `site_reads(site, func, kind, source)` and `call_arg_reads(caller,
    callee, arg_pos, kind, source)` — the same questions by data alone:
    what the operation's or the argument's value is made of, not what it
    runs under. A check-then-act race that writes back what it read is a
    lost update; one whose write only runs because of the read, with a
    value from elsewhere, may be a refill both racers agree on.

  The call relations are per function, not per site: an edit that keeps
  the flow does not move them, and they stay out of the volatile
  instruction-level input set (`priv/dl/stage0.dl`).

  ## What a call's result is made of

  A remote call's result depends on its arguments as well as on the call:
  `Enum.empty?(Registry.lookup(r, k))` decides exactly as the lookup
  does, and nothing summarizes code outside the module. A local call's
  result does not: the callee's `returns_depends` says which parameters
  reach it, and composing that per call keeps one caller's argument from
  leaking into every other caller's result. A `call_fun` or `apply`
  result depends on its arguments only.

  ## What is not emitted

  A call into the runtime's own applications (erts, kernel, stdlib,
  elixir, logger) that is not a shared-state operation holds no race site
  and is no project's lookup helper: no row names it as a callee, and its
  result is not a `call` source — it carries only what its arguments did.
  On ecto that removes about half of the rows.

  Not followed: exception edges (`Argus.Dataflow` does not walk them),
  and values carried in a process's state or mailbox — the next callback
  invocation is not a call.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Function, as: CfgFunction
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Runtime
  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.ETS
  alias Argus.Extractors.Mnesia
  alias Argus.Extractors.ProcessRegistry
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3]

  # A fixpoint over a finite lattice converges; the bound only guards a bug.
  @max_evaluations 64

  @typep source :: {:param, non_neg_integer()} | {:call, String.t()} | {:site, String.t()}
  @typep deps :: MapSet.t(source())

  @impl true
  def relations,
    do: [
      :call_arg_depends,
      :call_arg_reads,
      :call_decided,
      :returns_depends,
      :site_depends,
      :site_reads
    ]

  @doc """
  Whether a remote call is a shared-state operation: a read or a write of
  the process registry, an ETS table or a Mnesia table, as each family's
  extractor defines it.
  """
  @spec site?(mfa()) :: boolean()
  def site?(mfa), do: ProcessRegistry.site?(mfa) or ETS.site?(mfa) or Mnesia.site?(mfa)

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    with typed when typed != nil <- Helpers.typed(module_data),
         reaching when reaching != nil <- Helpers.reaching(module_data) do
      index = index(module_data, typed, reaching)

      module_data.functions
      |> Enum.reduce(%{}, fn {:function, name, arity, _entry, _instrs}, acc ->
        func_id = Normalize.func_id(module_data.module, name, arity)

        case Helpers.cfg(module_data, name, arity) do
          nil -> acc
          fun -> function_facts(acc, func_id, fun, function_index(index, func_id))
        end
      end)
      |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    else
      nil -> %{}
    end
  end

  # ── The module, indexed per function ────────────────────────────────

  # Each part keyed by function ID, then by instruction index.
  defp index(module_data, typed, reaching) do
    calls =
      module_data
      |> CallSites.for_module()
      |> Enum.reduce(%{}, fn %{func_id: f, idx: idx, mfa: mfa, remote?: remote?}, acc ->
        Map.update(acc, f, %{idx => {mfa, remote?}}, &Map.put(&1, idx, {mfa, remote?}))
      end)

    %{
      reads: ValueFlow.reads_by_function(reaching),
      writes: by_function(Map.get(typed, :def, []), &{&1.id, &1.reg}, :list),
      ops: by_function(Map.get(typed, :instruction, []), &{&1.id, &1.op}, :one),
      tails: by_function(Map.get(typed, :tail_call, []), &{&1.id, true}, :one),
      calls: calls,
      copies: by_function(Helpers.copies(module_data), fn {id, instr} -> {id, instr} end, :one),
      closures: closures(module_data)
    }
  end

  defp function_index(index, func_id),
    do: Map.new(index, fn {part, by} -> {part, Map.get(by, func_id, %{})} end)

  # %{func_id => %{idx => value}} (or a list of the values, in order),
  # naming each function once rather than once per row.
  defp by_function(rows, pair, shape) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      {%InstrId{module: m, func: f, arity: a, idx: idx}, value} = pair.(row)

      Map.update(acc, {m, f, a}, %{idx => [value]}, fn by_idx ->
        Map.update(by_idx, idx, [value], &[value | &1])
      end)
    end)
    |> Map.new(fn {{m, f, a}, by_idx} ->
      values =
        case shape do
          :list -> Map.new(by_idx, fn {idx, values} -> {idx, Enum.reverse(values)} end)
          :one -> Map.new(by_idx, fn {idx, [value | _]} -> {idx, value} end)
        end

      {InstrId.func_id(m, f, a), values}
    end)
  end

  # make_fun3 sites: the closure, its first environment parameter, and the
  # environment operands.
  defp closures(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions, into: %{} do
      sites =
        for {{:make_fun3, {cmod, cname, carity}, _index, _uniq, _dst, {:list, env}}, idx} <-
              Enum.with_index(instrs),
            into: %{},
            do: {idx, {Normalize.func_id(cmod, cname, carity), carity - length(env), env}}

      {Normalize.func_id(mod, name, arity), sites}
    end
  end

  # ── One function ────────────────────────────────────────────────────

  defp function_facts(facts, func_id, %CfgFunction{} = fun, index) do
    idxs =
      fun.blocks
      |> Map.values()
      |> Enum.flat_map(fn %{range: {first, last}} -> Enum.to_list(first..last//1) end)
      |> Enum.sort()

    block_of =
      for {id, %{range: {first, last}}} <- fun.blocks,
          idx <- first..last//1,
          into: %{},
          do: {idx, id}

    deciders = CfgFunction.control_deps(fun)

    ctx = %{
      func_id: func_id,
      index: index,
      block_of: block_of,
      deciders: deciders,
      decider_of: decider_of(fun, deciders),
      decided: decided(fun, deciders)
    }

    {outs, tested} = solve(idxs, ctx)
    facts = Enum.reduce(idxs, facts, &emit(&2, &1, ctx, outs, tested))

    # The same flow with no decision counted: what an argument is made
    # of, as opposed to what it runs under.
    data_ctx = %{ctx | deciders: %{}, decider_of: %{}, decided: %{}}
    {data_outs, _} = solve(idxs, data_ctx)
    Enum.reduce(idxs, facts, &emit_reads(&2, &1, data_ctx, data_outs))
  end

  # Every write's sources, and what each deciding block's decision
  # depends on (`tested`: the values its terminator reads, and whatever
  # decided that block in turn). A block runs because of every block
  # deciding it, so when a decision's sources change the instructions of
  # the blocks it decides are evaluated again.
  defp solve(idxs, ctx) do
    ValueFlow.solve(
      idxs,
      ctx.index.reads,
      %{},
      fn idx, outs, tested ->
        inputs = inputs_of(idx, ctx, outs)
        here = ctrl(Map.get(ctx.block_of, idx), ctx, tested)

        writes =
          for reg <- Map.get(ctx.index.writes, idx, []),
              do: {reg, result(idx, reg, inputs, here, ctx)}

        case Map.fetch(ctx.decider_of, idx) do
          {:ok, decider} ->
            decision = inputs |> union() |> MapSet.union(ctrl(decider, ctx, tested))

            if Map.get(tested, decider) == decision,
              do: {writes, tested, []},
              else:
                {writes, Map.put(tested, decider, decision), Map.get(ctx.decided, decider, [])}

          :error ->
            {writes, tested, []}
        end
      end,
      max_evaluations: @max_evaluations
    )
  end

  # What a block runs under: the decisions of the blocks deciding it.
  defp ctrl(block, ctx, tested) do
    ctx.deciders
    |> Map.get(block, [])
    |> Enum.reduce(MapSet.new(), &MapSet.union(&2, Map.get(tested, &1, MapSet.new())))
  end

  # %{terminator idx => block}: the last instruction of each block that
  # decides another.
  defp decider_of(fun, deciders) do
    for {_block, ds} <- deciders,
        d <- ds,
        into: %{},
        do: {elem(Map.fetch!(fun.blocks, d).range, 1), d}
  end

  # %{decider => [idx]}: the instructions of the blocks each decides.
  defp decided(fun, deciders) do
    Enum.reduce(deciders, %{}, fn {block, ds}, acc ->
      {first, last} = Map.fetch!(fun.blocks, block).range
      idxs = Enum.to_list(first..last//1)
      Enum.reduce(ds, acc, fn d, inner -> Map.update(inner, d, idxs, &(idxs ++ &1)) end)
    end)
  end

  # What each register the instruction reads depends on.
  @spec inputs_of(non_neg_integer(), map(), map()) :: %{String.t() => deps()}
  defp inputs_of(idx, ctx, outs), do: ValueFlow.inputs(ctx.index.reads, outs, idx, &{:param, &1})

  # What the value written at `idx` depends on, given its inputs and the
  # decisions its block runs under.
  defp result(idx, reg, inputs, here, ctx) do
    base =
      case {Map.fetch(ctx.index.calls, idx), Map.fetch(ctx.index.copies, idx)} do
        {{:ok, call}, _copy} -> call_result(idx, call, inputs, ctx)
        {:error, {:ok, copy}} -> copied(copy, reg, inputs)
        {:error, :error} -> union(inputs)
      end

    MapSet.union(base, here)
  end

  defp call_result(idx, {{mod, fun, arity} = mfa, remote?}, inputs, ctx) do
    cond do
      not remote? -> MapSet.new([{:call, Normalize.func_id(mod, fun, arity)}])
      site?(mfa) -> MapSet.put(union(inputs), {:site, InstrId.mint(ctx.func_id, idx)})
      runtime?(mod) -> union(inputs)
      true -> MapSet.put(union(inputs), {:call, Normalize.func_id(mod, fun, arity)})
    end
  end

  # A copy (move, swap, trim) writes each register from the one it
  # copied; a union over its reads would mix a trim's renumbered slots.
  defp copied(copy, reg, inputs) do
    case Helpers.copy_read(copy, reg) do
      nil -> MapSet.new()
      read -> Map.get(inputs, read, MapSet.new())
    end
  end

  defp runtime?(mod), do: Runtime.module?(mod)

  defp union(inputs), do: inputs |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

  # ── Emission ────────────────────────────────────────────────────────

  defp emit(facts, idx, ctx, outs, tested) do
    here = ctrl(Map.get(ctx.block_of, idx), ctx, tested)
    inputs = inputs_of(idx, ctx, outs)

    facts
    |> emit_call(Map.get(ctx.index.calls, idx), idx, inputs, here, ctx)
    |> emit_closure(Map.get(ctx.index.closures, idx), inputs, here, ctx)
    |> emit_return(idx, inputs, here, ctx)
  end

  defp emit_call(facts, nil, _idx, _inputs, _here, _ctx), do: facts

  defp emit_call(facts, {{mod, fun, arity} = mfa, remote?}, idx, inputs, here, ctx) do
    cond do
      remote? and site?(mfa) ->
        site = InstrId.mint(ctx.func_id, idx)
        rows(facts, :site_depends, [site, ctx.func_id], MapSet.union(here, union(inputs)))

      remote? and runtime?(mod) ->
        facts

      true ->
        callee = Normalize.func_id(mod, fun, arity)
        facts = rows(facts, :call_decided, [ctx.func_id, callee], here)

        Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
          rows(
            acc,
            :call_arg_depends,
            [ctx.func_id, callee, to_string(pos)],
            Map.get(inputs, "x#{pos}", MapSet.new())
          )
        end)
    end
  end

  # The data-only rows: a site's arguments and a call's, by what they are
  # made of. Closures are not followed here: a captured value is made of
  # what the closure body does with it, which is the closure's own
  # function's question.
  defp emit_reads(facts, idx, ctx, outs) do
    case Map.get(ctx.index.calls, idx) do
      nil ->
        facts

      {{mod, fun, arity} = mfa, remote?} ->
        inputs = inputs_of(idx, ctx, outs)

        cond do
          remote? and site?(mfa) ->
            site = InstrId.mint(ctx.func_id, idx)
            rows(facts, :site_reads, [site, ctx.func_id], union(inputs))

          remote? and runtime?(mod) ->
            facts

          true ->
            callee = Normalize.func_id(mod, fun, arity)

            Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
              rows(
                acc,
                :call_arg_reads,
                [ctx.func_id, callee, to_string(pos)],
                Map.get(inputs, "x#{pos}", MapSet.new())
              )
            end)
        end
    end
  end

  defp emit_closure(facts, nil, _inputs, _here, _ctx), do: facts

  defp emit_closure(facts, {closure, first, env}, inputs, here, ctx) do
    facts = rows(facts, :call_decided, [ctx.func_id, closure], here)

    env
    |> Enum.with_index(first)
    |> Enum.reduce(facts, fn {operand, pos}, acc ->
      case register(operand) do
        {kind, n} when kind in [:x, :y] ->
          rows(
            acc,
            :call_arg_depends,
            [ctx.func_id, closure, to_string(pos)],
            Map.get(inputs, "#{kind}#{n}", MapSet.new())
          )

        _literal ->
          acc
      end
    end)
  end

  # What a function returns: x0 at a return, or a tail call's result.
  defp emit_return(facts, idx, inputs, here, ctx) do
    cond do
      Map.has_key?(ctx.index.tails, idx) ->
        rows(facts, :returns_depends, [ctx.func_id], result(idx, "x0", inputs, here, ctx))

      Map.get(ctx.index.ops, idx) == "return" ->
        rows(
          facts,
          :returns_depends,
          [ctx.func_id],
          MapSet.union(Map.get(inputs, "x0", MapSet.new()), here)
        )

      true ->
        facts
    end
  end

  defp rows(facts, relation, prefix, deps) do
    Enum.reduce(deps, facts, fn source, acc ->
      add_fact(acc, relation, prefix ++ encode(source))
    end)
  end

  defp encode({:param, k}), do: ["param", to_string(k)]
  defp encode({:call, callee}), do: ["call", callee]
  defp encode({:site, site}), do: ["site", site]
end
