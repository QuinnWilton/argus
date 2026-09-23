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
  alias Argus.Extractors.ETS
  alias Argus.Extractors.Mnesia
  alias Argus.Extractors.ProcessRegistry
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [add_fact: 3, register: 1]

  # A fixpoint over a finite lattice converges; the bound only guards a bug.
  @max_passes 64

  @runtime_modules for app <- [:erts, :kernel, :stdlib, :elixir, :logger],
                       _ = Application.load(app),
                       mod <- Application.spec(app, :modules) || [],
                       into: MapSet.new(),
                       do: mod

  @typep source :: {:param, non_neg_integer()} | {:call, String.t()} | {:site, String.t()}
  @typep deps :: MapSet.t(source())

  @impl true
  def relations, do: [:call_arg_depends, :call_decided, :returns_depends, :site_depends]

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
          fun -> function_facts(acc, func_id, fun, index)
        end
      end)
      |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    else
      nil -> %{}
    end
  end

  # ── The module, indexed per function ────────────────────────────────

  defp index(module_data, typed, reaching) do
    reads =
      Enum.group_by(
        reaching,
        fn {_source, _reg, use} -> {func_of(use), use.idx} end,
        fn
          {{:param, k}, reg, _use} -> {reg, {:param, k}}
          {%InstrId{idx: d}, reg, _use} -> {reg, {:def, d}}
        end
      )

    writes =
      typed
      |> Map.get(:def, [])
      |> Enum.group_by(&{func_of(&1.id), &1.id.idx}, & &1.reg)

    ops = Map.new(Map.get(typed, :instruction, []), &{{func_of(&1.id), &1.id.idx}, &1.op})
    tails = MapSet.new(Map.get(typed, :tail_call, []), &{func_of(&1.id), &1.id.idx})

    calls =
      module_data
      |> CallSites.for_module()
      |> Map.new(fn %{func_id: f, idx: idx, mfa: mfa, remote?: remote?} ->
        {{f, idx}, {mfa, remote?}}
      end)

    %{
      reads: reads,
      writes: writes,
      ops: ops,
      tails: tails,
      calls: calls,
      closures: closures(module_data)
    }
  end

  defp func_of(%InstrId{module: m, func: f, arity: a}), do: InstrId.func_id(m, f, a)

  # make_fun3 sites: the closure, its first environment parameter, and the
  # environment operands.
  defp closures(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        func_id = Normalize.func_id(mod, name, arity),
        {{:make_fun3, {cmod, cname, carity}, _index, _uniq, _dst, {:list, env}}, idx} <-
          Enum.with_index(instrs),
        into: %{} do
      {{func_id, idx}, {Normalize.func_id(cmod, cname, carity), carity - length(env), env}}
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

    ctx = %{
      func_id: func_id,
      index: index,
      block_of: block_of,
      deciders: CfgFunction.control_deps(fun),
      terminator: Map.new(fun.blocks, fn {id, %{range: {_first, last}}} -> {id, last} end)
    }

    {outs, ctrl} = fixpoint(idxs, ctx, %{}, %{}, 0)
    Enum.reduce(idxs, facts, &emit(&2, &1, ctx, outs, ctrl))
  end

  defp fixpoint(idxs, ctx, outs, ctrl, pass) when pass < @max_passes do
    new_ctrl =
      Map.new(ctx.terminator, fn {block, _last} -> {block, ctrl_of(block, ctx, outs, ctrl)} end)

    new_outs =
      Enum.reduce(idxs, outs, fn idx, acc ->
        inputs = inputs_of(idx, ctx, acc)
        here = Map.get(new_ctrl, Map.get(ctx.block_of, idx), MapSet.new())

        ctx.index.writes
        |> Map.get({ctx.func_id, idx}, [])
        |> Enum.reduce(acc, fn reg, inner ->
          Map.put(inner, {idx, reg}, result(idx, inputs, here, ctx))
        end)
      end)

    if new_outs == outs and new_ctrl == ctrl,
      do: {outs, ctrl},
      else: fixpoint(idxs, ctx, new_outs, new_ctrl, pass + 1)
  end

  defp fixpoint(_idxs, _ctx, outs, ctrl, _pass), do: {outs, ctrl}

  # A block runs because of every block deciding it: the values the
  # deciding branch tests, and whatever decided that branch in turn.
  defp ctrl_of(block, ctx, outs, ctrl) do
    ctx.deciders
    |> Map.get(block, [])
    |> Enum.reduce(MapSet.new(), fn decider, acc ->
      tested = ctx.terminator |> Map.fetch!(decider) |> inputs_of(ctx, outs) |> union()
      acc |> MapSet.union(tested) |> MapSet.union(Map.get(ctrl, decider, MapSet.new()))
    end)
  end

  # What each register the instruction reads depends on.
  @spec inputs_of(non_neg_integer(), map(), map()) :: %{String.t() => deps()}
  defp inputs_of(idx, ctx, outs) do
    ctx.index.reads
    |> Map.get({ctx.func_id, idx}, [])
    |> Enum.reduce(%{}, fn {reg, source}, acc ->
      deps =
        case source do
          {:param, k} -> MapSet.new([{:param, k}])
          {:def, d} -> Map.get(outs, {d, reg}, MapSet.new())
        end

      Map.update(acc, reg, deps, &MapSet.union(&1, deps))
    end)
  end

  # What the value written at `idx` depends on, given its inputs and the
  # decisions its block runs under.
  defp result(idx, inputs, here, ctx) do
    key = {ctx.func_id, idx}

    base =
      case Map.fetch(ctx.index.calls, key) do
        {:ok, call} -> call_result(idx, call, inputs, ctx)
        :error -> union(inputs)
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

  defp runtime?(mod), do: MapSet.member?(@runtime_modules, mod)

  defp union(inputs), do: inputs |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

  # ── Emission ────────────────────────────────────────────────────────

  defp emit(facts, idx, ctx, outs, ctrl) do
    key = {ctx.func_id, idx}
    here = Map.get(ctrl, Map.get(ctx.block_of, idx), MapSet.new())
    inputs = inputs_of(idx, ctx, outs)

    facts
    |> emit_call(Map.get(ctx.index.calls, key), idx, inputs, here, ctx)
    |> emit_closure(Map.get(ctx.index.closures, key), inputs, here, ctx)
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
    key = {ctx.func_id, idx}

    cond do
      MapSet.member?(ctx.index.tails, key) ->
        rows(facts, :returns_depends, [ctx.func_id], result(idx, inputs, here, ctx))

      Map.get(ctx.index.ops, key) == "return" ->
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
