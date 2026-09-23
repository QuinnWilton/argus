defmodule Argus.Extractors.ParamFlow do
  @moduledoc """
  Which of a function's parameters each call argument is derived from.

  `call_arg_forward` says an argument IS the caller's parameter; this says
  it is *made from* one — destructured out of it, built into a tuple or a
  binary with it, or returned by a call that hands its argument's data
  through (`Propagators`). It is the per-function summary a taint query
  chains: an entry point's request parameter reaches a sink when every hop
  along the way hands data derived from its parameter to the next.

  ## Emitted facts

  - `call_arg_derived(caller, callee, arg_pos, param_pos)` — at some call
    site in `caller`, argument `arg_pos` is data-dependent on `caller`'s
    parameter `param_pos`. Closure construction counts as a call: the
    environment slot `i` of a `make_fun3` is the closure's parameter
    `arity - env_len + i`, so a captured variable flows into the closure
    body the same way an argument flows into a callee.
  - `sink_arg_derived(id, func, arg_pos, param_pos)` — the same, at a sink
    call site (`Argus.Extractors.ApiCalls.sink_mfas/0`), keyed on the site
    because the finding anchors there.

  ## Reading the bytecode

  Reaching definitions (`Argus.Dataflow.reaching_uses/2`) with the
  parameters as sources give, for every register an instruction reads,
  which writes — or which parameter — can have produced it. The extractor
  then runs a union fixpoint over each function
  (`Argus.Extractor.ValueFlow`): a structural instruction (`move`,
  `get_tuple_element`, `get_map_elements`, `put_tuple2`, `bs_create_bin`,
  ...) derives every register it writes from every one it reads; a call derives its result only when the callee is a propagator,
  and then only from the positions the table names; a BIF only when it is
  one of the listed structural BIFs; a local call, `call_fun` or `apply`
  derives nothing — the callee's own summary carries that flow, and a
  callee this module knows nothing about must not launder its argument
  into a fresh-looking result. Every failure to follow a flow therefore
  loses a finding rather than inventing one.

  A copy — `move`, `swap`, `trim` — derives each register it writes from
  the one register it copied (`Helpers.copy_read/2`): a `trim` renumbers
  the stack frame slot by slot, and a union over its reads would hand
  every kept slot every other slot's parameters.

  Not followed, by design: element flow through a higher-order function's
  closure (`Enum.map(params, fn p -> ... end)`:
  the closure's parameter is the element, which no fact ties to the
  collection), and a local helper's return value.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.ApiCalls
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3]

  @max_args 4

  @impl true
  def relations, do: [:call_arg_derived, :sink_arg_derived]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    with typed when typed != nil <- Helpers.typed(module_data),
         reaching when reaching != nil <- Helpers.reaching(module_data) do
      inputs = derive(typed, reaching, Helpers.copies(module_data), bif_operands(module_data))

      %{}
      |> emit_call_sites(module_data, inputs)
      |> emit_closures(module_data, inputs)
      |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    else
      nil -> %{}
    end
  end

  # ── The fixpoint ─────────────────────────────────────────────────────

  # Per function, what each write is derived from, with the reads the
  # values are joined over: %{func_id => {reads, outs}}.
  defp derive(typed, triples, copies, bif_operands) do
    writes =
      typed
      |> Map.get(:def, [])
      |> Enum.group_by(& &1.id, & &1.reg)

    ops = Map.new(Map.get(typed, :instruction, []), &{&1.id, &1.op})
    remote = Map.new(Map.get(typed, :remote_call, []), &{&1.id, {&1.mod, &1.func, &1.arity}})
    bifs = Map.new(Map.get(typed, :bif_call, []), &{&1.id, &1.func})
    tails = MapSet.new(Map.get(typed, :tail_call, []), & &1.id)
    locals = MapSet.new(Map.get(typed, :local_call, []), & &1.id)
    dynamics = MapSet.new(Map.get(typed, :dynamic_call, []), & &1.id)

    ctx = %{
      writes: writes,
      ops: ops,
      remote: remote,
      bifs: bifs,
      tails: tails,
      locals: locals,
      dynamics: dynamics,
      copies: copies,
      bif_operands: bif_operands
    }

    reads = ValueFlow.reads_by_function(triples)

    typed
    |> Map.get(:instruction, [])
    |> Enum.group_by(&{&1.id.module, &1.id.func, &1.id.arity}, & &1.id)
    |> Map.new(fn {{m, f, a}, ids} ->
      func_id = InstrId.func_id(m, f, a)
      func_reads = Map.get(reads, func_id, %{})
      by_idx = Map.new(ids, &{&1.idx, &1})

      {outs, nil} =
        ValueFlow.solve(by_idx |> Map.keys() |> Enum.sort(), func_reads, nil, fn idx, outs, nil ->
          id = Map.fetch!(by_idx, idx)
          inputs = ValueFlow.inputs(func_reads, outs, idx, & &1)
          all_inputs = inputs |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

          derived =
            for reg <- Map.get(ctx.writes, id, []),
                do: {reg, transfer(id, reg, inputs, all_inputs, ctx)}

          {derived, nil, []}
        end)

      {func_id, {func_reads, outs}}
    end)
  end

  # What each register instruction `idx` of `func_id` reads is derived
  # from.
  defp inputs_at(derived, func_id, idx) do
    case Map.fetch(derived, func_id) do
      {:ok, {reads, outs}} -> ValueFlow.inputs(reads, outs, idx, & &1)
      :error -> %{}
    end
  end

  # What the register written at `id` is derived from.
  defp transfer(id, reg, inputs, all_inputs, ctx) do
    cond do
      MapSet.member?(ctx.tails, id) ->
        MapSet.new()

      Map.has_key?(ctx.remote, id) ->
        {mod, fun, arity} = Map.fetch!(ctx.remote, id)

        case Propagators.positions(mod, fun, arity) do
          nil -> MapSet.new()
          positions -> union_of(inputs, Enum.map(positions, &"x#{&1}"))
        end

      MapSet.member?(ctx.locals, id) or MapSet.member?(ctx.dynamics, id) ->
        MapSet.new()

      Map.has_key?(ctx.bifs, id) ->
        bif_transfer(Map.fetch!(ctx.bifs, id), Map.get(ctx.bif_operands, id, []), inputs)

      Map.get(ctx.ops, id) in ~w(make_fun3 call_fun call_fun2 apply apply_last) ->
        MapSet.new()

      # A copy writes each register from the one it copied.
      Map.has_key?(ctx.copies, id) ->
        case Helpers.copy_read(Map.fetch!(ctx.copies, id), reg) do
          nil -> MapSet.new()
          read -> Map.get(inputs, read, MapSet.new())
        end

      true ->
        # A structural instruction: every write is made from every read.
        all_inputs
    end
  end

  # A BIF's result carries the operands its signature says it does; an
  # operand that is not a register (a literal key) carries nothing.
  defp bif_transfer(fun, operands, inputs) do
    case Propagators.bif_positions(fun, length(operands)) do
      nil -> MapSet.new()
      positions -> union_of(inputs, for(p <- positions, reg = Enum.at(operands, p), do: reg))
    end
  end

  # %{id => operands}: each BIF instruction's operands in order, a
  # register spelled as the facts spell it (`"x0"`), anything else nil.
  defp bif_operands(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        func_id = Normalize.func_id(mod, name, arity),
        {instr, idx} <- Enum.with_index(instrs),
        operands = bif_args(instr),
        operands != nil,
        {:ok, id} = InstrId.parse(InstrId.mint(func_id, idx)),
        into: %{},
        do: {id, Enum.map(operands, &spelled_register/1)}
  end

  defp bif_args({:bif, _name, _fail, args, _dst}) when is_list(args), do: args
  defp bif_args({:gc_bif, _name, _fail, _live, args, _dst}) when is_list(args), do: args
  defp bif_args(_instr), do: nil

  defp spelled_register(operand) do
    case register(operand) do
      {kind, n} when kind in [:x, :y] -> "#{kind}#{n}"
      _ -> nil
    end
  end

  defp union_of(inputs, regs) do
    Enum.reduce(regs, MapSet.new(), fn reg, acc ->
      MapSet.union(acc, Map.get(inputs, reg, MapSet.new()))
    end)
  end

  # ── Emission ─────────────────────────────────────────────────────────

  defp emit_call_sites(facts, module_data, inputs) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(facts, fn %{func_id: func_id, idx: idx, mfa: {mod, fun, arity} = mfa}, acc ->
      id = InstrId.mint(func_id, idx)
      site_inputs = inputs_at(inputs, func_id, idx)
      callee = Normalize.func_id(mod, fun, arity)
      sink? = ApiCalls.sink?(mfa)

      Enum.reduce(0..(arity - 1)//1, acc, fn pos, inner ->
        derived = Map.get(site_inputs, "x#{pos}", MapSet.new())
        inner = emit_call_arg(inner, [func_id, callee, to_string(pos)], derived, pos)
        if sink?, do: emit_sink_arg(inner, [id, func_id, to_string(pos)], derived), else: inner
      end)
    end)
  end

  # The environment of a closure built with a concrete MFA is its trailing
  # parameters: slot i is parameter arity - env_len + i.
  defp emit_closures(facts, %{module: mod, functions: functions}, inputs) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn
        {{:make_fun3, {cmod, cname, carity}, _index, _uniq, _dst, {:list, env}}, idx}, inner ->
          site_inputs = inputs_at(inputs, func_id, idx)
          closure = Normalize.func_id(cmod, cname, carity)
          first = carity - length(env)

          env
          |> Enum.with_index()
          |> Enum.reduce(inner, fn {operand, slot}, deep ->
            case register(operand) do
              {kind, n} when kind in [:x, :y] ->
                derived = Map.get(site_inputs, "#{kind}#{n}", MapSet.new())

                emit_call_arg(
                  deep,
                  [func_id, closure, to_string(first + slot)],
                  derived,
                  first + slot
                )

              _literal ->
                deep
            end
          end)

        _other, inner ->
          inner
      end)
    end)
  end

  # Only the first @max_args positions of a call, like call_arg.
  defp emit_call_arg(facts, _prefix, _derived, pos) when pos >= @max_args, do: facts

  defp emit_call_arg(facts, prefix, derived, _pos) do
    Enum.reduce(derived, facts, fn param, acc ->
      add_fact(acc, :call_arg_derived, prefix ++ [to_string(param)])
    end)
  end

  # A sink's every position, since the finding hangs on it.
  defp emit_sink_arg(facts, prefix, derived) do
    Enum.reduce(derived, facts, fn param, acc ->
      add_fact(acc, :sink_arg_derived, prefix ++ [to_string(param)])
    end)
  end
end
