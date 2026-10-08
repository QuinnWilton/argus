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
  - `call_arg_param(id, func, arg_pos, param_pos)` — the same provenance
    at every concrete local or remote call site, preserving invocation
    identity when two calls to one callee have different data or guards.
  - `call_arg_runtime(id, func, arg_pos, source, source_func)` — data
    returned by an unresolved direct fun invocation reaches this argument.
    The invocation is an independent origin, not a claim that its arguments
    become its result or that the caller controls the returned content.
  - `sink_arg_bounded(id, func, arg_pos, list_param)` — the sink's
    argument is one of a set the program wrote, on every path to it:
    compared equal to a literal, found in a literal list on the branch
    where it holds, or an integer between two close ends, at most 1,024
    values in all — or, at an atom sink, made of atoms that exist
    (`Argus.Extractors.ParamFlow.Bounded`). `list_param` is empty for
    the first; `"atoms"` for the second, which holds only where the rules
    find the atoms are not the caller's choice (below); otherwise the
    function's parameter that list is, which the callers must fill with a
    literal list.
  - `call_arg_chosen(caller, callee, arg_pos)` and `sink_arg_chosen(id,
    func, arg_pos)` — the argument is made of an atom an existing-atom
    lookup returned (`String.to_existing_atom/1`,
    `:erlang.binary_to_existing_atom/2`, `List.to_existing_atom/1`): one
    of the atoms that exist, of the caller's choosing. An atom made of it
    grows the set it was chosen from, one per call — the next caller names
    the atom the last one made — so it is no atoms-of-atoms bound.
  - `call_arg_allowlist(caller, callee, arg_pos)` — every call the caller
    makes to the callee passes a literal list at `arg_pos`.
  - `sink_copy(id, func, first)` — the sink call at `id` repeats `first`,
    the earliest call of the same API in the function on the same source
    line: code the compiler duplicated. A copy is made of what `first` is
    made of (`sink_arg_derived` alike), or sits on a path that excludes
    `first`'s; two calls one after the other on one line whose arguments
    come from different places are two calls, not copies.

  ## Reading the bytecode

  Reaching definitions (`Argus.Dataflow.reaching_uses/2`) with the
  parameters as sources give, for every register an instruction reads,
  which writes — or which parameter — can have produced it. The extractor
  then runs a union fixpoint over each function
  (`Argus.Extractor.ValueFlow`): a structural instruction (`move`,
  `get_tuple_element`, `get_map_elements`, `put_tuple2`, `bs_create_bin`,
  ...) derives every register it writes from every one it reads. A known
  external propagator derives its result from the positions the table
  names; a BIF only from the listed structural operands. A same-module
  call uses the callee's parameter-to-return summary, including tail calls
  and recursive helpers. These summaries converge together from empty
  sets, and keep each invocation's argument positions distinct. Unknown
  external callees and unresolved dynamic calls derive no parameters; an
  unresolved direct fun invocation supplies its own runtime-content origin.

  A copy — `move`, `swap`, `trim` — derives each register it writes from
  the one register it copied (`Helpers.copy_read/2`): a `trim` renumbers
  the stack frame slot by slot, and a union over its reads would hand
  every kept slot every other slot's parameters.

  A higher-order call hands each element of its collection to the fun it
  runs: a closure the caller builds and hands to `Enum.map/2`,
  `Map.new/2`, `:lists.foldl/3` and the like takes the element as its
  first parameter, derived from what the collection is. Supported mapping
  and reduction calls also carry the closure's actual return data back,
  including captured values as they were at closure construction. A
  mapper returning a constant does not hand its element's data through.
  Funs whose bodies are unavailable are not followed.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Function, as: CfgFunction
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.ApiCalls
  alias Argus.Extractors.ParamFlow.Bounded
  alias Argus.Extractors.ParamFlow.Cookies
  alias Argus.Extractors.ParamFlow.PrivateBounds
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.Extractors.ParamFlow.Returns
  alias Argus.Extractors.ParamFlow.SequenceBounds
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Disassemble
  alias Argus.Pipeline.Normalize

  import Argus.Instr, only: [register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3]

  @max_args 4

  # The lookups that answer an atom that exists, named by a string the
  # caller hands them: what they return is the caller's choice among the
  # atoms that exist (the `chosen` marker, `call_arg_chosen`).
  @choosers MapSet.new([
              {":erlang", "binary_to_existing_atom", 1},
              {":erlang", "binary_to_existing_atom", 2},
              {":erlang", "list_to_existing_atom", 1},
              {"String", "to_existing_atom", 1},
              {"List", "to_existing_atom", 1}
            ])

  @impl true
  def relations,
    do: [
      :call_arg_allowlist,
      :call_arg_chosen,
      :call_arg_derived,
      :call_arg_param,
      :call_arg_runtime,
      :sink_arg_bounded,
      :sink_arg_chosen,
      :sink_arg_derived,
      :sink_copy
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    with typed when typed != nil <- Helpers.typed(module_data),
         reaching when reaching != nil <- Helpers.reaching(module_data) do
      inputs =
        derive(
          typed,
          reaching,
          Helpers.copies(module_data),
          bif_operands(module_data),
          Cookies.server_writes(module_data),
          Returns.index(module_data)
        )

      %{}
      |> emit_call_sites(module_data, inputs)
      |> emit_closures(module_data, inputs)
      |> emit_bounded_sinks(module_data)
      |> emit_allowlists(module_data)
      |> emit_sink_copies(module_data, inputs)
      |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    else
      nil -> %{}
    end
  end

  # ── The fixpoint ─────────────────────────────────────────────────────

  # Per function, what each write is derived from, with the reads the
  # values are joined over: %{func_id => {reads, outs}}.
  defp derive(typed, triples, copies, bif_operands, server_writes, {targets, callbacks}) do
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
      bif_operands: bif_operands,
      server_writes: server_writes,
      targets: targets,
      callbacks: callbacks
    }

    reads = ValueFlow.reads_by_function(triples)

    functions =
      typed
      |> Map.get(:instruction, [])
      |> Enum.group_by(&{&1.id.module, &1.id.func, &1.id.arity}, & &1.id)
      |> Map.new(fn {{m, f, a}, ids} ->
        func_id = InstrId.func_id(m, f, a)
        func_reads = Map.get(reads, func_id, %{})
        by_idx = Map.new(ids, &{&1.idx, &1})
        func_callbacks = Map.take(callbacks, ids)
        capture_users = Returns.capture_users(func_callbacks, func_reads)
        {func_id, {func_reads, by_idx, capture_users}}
      end)

    ctx = Map.put(ctx, :functions, functions)

    Returns.solve(functions, targets, callbacks, fn function, summaries ->
      solve_function(function, Map.put(ctx, :summaries, summaries))
    end)
  end

  defp solve_function({reads, by_idx, capture_users}, ctx) do
    idxs = by_idx |> Map.keys() |> Enum.sort()

    {outs, nil} =
      ValueFlow.solve(idxs, reads, nil, fn idx, outs, nil ->
        id = Map.fetch!(by_idx, idx)
        inputs = ValueFlow.inputs(reads, outs, idx, & &1)
        all_inputs = inputs |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)
        at = fn i -> ValueFlow.inputs(reads, outs, i, & &1) end
        ctx = Map.put(ctx, :at, at)

        derived =
          for reg <- Map.get(ctx.writes, id, []),
              do: {reg, transfer(id, reg, inputs, all_inputs, ctx)}

        changed? = Enum.any?(derived, fn {reg, value} -> Map.get(outs, {idx, reg}) != value end)
        also = if changed?, do: Map.get(capture_users, idx, []), else: []
        {derived, nil, also}
      end)

    at = fn i -> ValueFlow.inputs(reads, outs, i, & &1) end
    ctx = Map.put(ctx, :at, at)

    summary =
      Enum.reduce(idxs, MapSet.new(), fn idx, acc ->
        id = Map.fetch!(by_idx, idx)

        cond do
          MapSet.member?(ctx.tails, id) ->
            MapSet.union(acc, call_result(id, at.(idx), ctx))

          Map.get(ctx.ops, id) == "return" ->
            MapSet.union(acc, Map.get(at.(idx), "x0", MapSet.new()))

          true ->
            acc
        end
      end)

    {{reads, outs}, summary}
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

      # A cookie the server verified (Cookies): its own bytes, not the
      # request's.
      MapSet.member?(ctx.server_writes, {id, reg}) ->
        MapSet.new()

      Map.has_key?(ctx.remote, id) or MapSet.member?(ctx.locals, id) or
          Map.has_key?(ctx.callbacks, id) ->
        call_result(id, inputs, ctx)

      MapSet.member?(ctx.dynamics, id) ->
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

  defp call_result(id, inputs, ctx) do
    target = Map.get(ctx.targets, id)

    cond do
      Map.has_key?(ctx.functions, target) ->
        Returns.substitute(Map.get(ctx.summaries, target, MapSet.new()), inputs)

      Map.has_key?(ctx.callbacks, id) ->
        callback = Map.fetch!(ctx.callbacks, id)

        if callback.closure == nil and Map.get(ctx.ops, id) in ["call_fun", "call_fun2"] do
          func = InstrId.func_id(id.module, id.func, id.arity)
          MapSet.new([{:runtime, func, InstrId.mint(func, id.idx)}])
        else
          Returns.callback_result(callback, inputs, ctx.summaries, ctx.at)
        end

      Map.has_key?(ctx.remote, id) ->
        {mod, fun, arity} = Map.fetch!(ctx.remote, id)

        derived =
          case Propagators.positions(mod, fun, arity) do
            nil -> MapSet.new()
            positions -> union_of(inputs, Enum.map(positions, &"x#{&1}"))
          end

        if MapSet.member?(@choosers, {mod, fun, arity}),
          do: MapSet.put(derived, :chosen),
          else: derived

      true ->
        MapSet.new()
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
        do: {id, Enum.map(operands, &Instr.spell_slot/1)}
  end

  defp bif_args({:bif, _name, _fail, args, _dst}) when is_list(args), do: args
  defp bif_args({:gc_bif, _name, _fail, _live, args, _dst}) when is_list(args), do: args
  defp bif_args(_instr), do: nil

  defp union_of(inputs, regs) do
    Enum.reduce(regs, MapSet.new(), fn reg, acc ->
      MapSet.union(acc, Map.get(inputs, reg, MapSet.new()))
    end)
  end

  # ── Emission ─────────────────────────────────────────────────────────

  defp emit_call_sites(facts, module_data, inputs) do
    instrs =
      Map.new(module_data.functions, fn {:function, n, a, _e, is} ->
        {Normalize.func_id(module_data.module, n, a), is}
      end)

    module_data
    |> CallSites.for_module()
    |> Enum.reduce(facts, fn %{func_id: func_id, idx: idx, mfa: {mod, fun, arity} = mfa}, acc ->
      id = InstrId.mint(func_id, idx)
      site_inputs = inputs_at(inputs, func_id, idx)
      callee = Normalize.func_id(mod, fun, arity)
      sink? = ApiCalls.sink?(mfa)

      acc =
        Enum.reduce(0..(arity - 1)//1, acc, fn pos, inner ->
          derived = Map.get(site_inputs, "x#{pos}", MapSet.new())
          inner = emit_call_arg(inner, [func_id, callee, to_string(pos)], derived, pos)

          inner =
            Enum.reduce(derived, inner, fn
              param, rows when is_integer(param) ->
                add_fact(rows, :call_arg_param, [id, func_id, to_string(pos), to_string(param)])

              {:runtime, source_func, source}, rows ->
                add_fact(rows, :call_arg_runtime, [
                  id,
                  func_id,
                  to_string(pos),
                  source,
                  source_func
                ])

              _marker, rows ->
                rows
            end)

          if sink?, do: emit_sink_arg(inner, [id, func_id, to_string(pos)], derived), else: inner
        end)

      emit_element_flow(acc, mfa, func_id, idx, site_inputs, instrs)
    end)
  end

  # A higher-order call hands each element of its collection to the fun it
  # runs: `Map.new(params, fn {k, v} -> ... end)` runs the closure on data
  # made of `params`. A closure the caller builds, at the fun position,
  # takes the element as its first parameter; its captured variables are
  # its trailing ones (emit_closures). {collection position, fun position}.
  @element_calls %{
    {Enum, :map, 2} => {0, 1},
    {Enum, :flat_map, 2} => {0, 1},
    {Enum, :each, 2} => {0, 1},
    {Enum, :filter, 2} => {0, 1},
    {Enum, :reject, 2} => {0, 1},
    {Enum, :find, 2} => {0, 1},
    {Enum, :group_by, 2} => {0, 1},
    {Enum, :sort_by, 2} => {0, 1},
    {Enum, :uniq_by, 2} => {0, 1},
    {Enum, :reduce, 3} => {0, 2},
    {Enum, :into, 3} => {0, 2},
    {Enum, :map_join, 3} => {0, 2},
    {Enum, :map_join, 2} => {0, 1},
    {Enum, :reduce, 2} => {0, 1},
    {Map, :new, 2} => {0, 1},
    {:lists, :map, 2} => {1, 0},
    {:lists, :foreach, 2} => {1, 0},
    {:lists, :filter, 2} => {1, 0},
    {:lists, :flatmap, 2} => {1, 0},
    {:lists, :foldl, 3} => {2, 0},
    {:lists, :foldr, 3} => {2, 0}
  }

  defp emit_element_flow(facts, mfa, func_id, idx, site_inputs, instrs) do
    with {:ok, {coll_pos, fun_pos}} <- Map.fetch(@element_calls, mfa),
         derived when derived != [] <-
           site_inputs |> Map.get("x#{coll_pos}", MapSet.new()) |> MapSet.to_list(),
         {:ok, fun_instrs} <- Map.fetch(instrs, func_id),
         closure when is_binary(closure) <- closure_at(fun_instrs, idx, {:x, fun_pos}) do
      emit_call_arg(facts, [func_id, closure, "0"], MapSet.new(derived), 0)
    else
      _ -> facts
    end
  end

  # The closure a register holds at a call: the make_fun3 it was built by.
  defp closure_at(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, nil, fn
      {_at, {:make_fun3, {mod, name, arity}, _index, _uniq, _dst, _env}}, _follow ->
        Normalize.func_id(mod, name, arity)

      _writer, _follow ->
        nil
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

  # ── Bounded sinks and literal lists ──────────────────────────────────

  # Each sink's arguments that are one of a set the program wrote on every
  # path to it. Only functions holding a sink are solved.
  defp emit_bounded_sinks(facts, %{module: mod, functions: functions} = module_data) do
    sinks =
      module_data
      |> CallSites.for_module()
      |> Enum.filter(&ApiCalls.sink?(&1.mfa))
      |> Enum.group_by(& &1.func_id)

    {entries, returns} = PrivateBounds.entries(module_data, Map.keys(sinks))

    facts =
      Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
        func_id = Normalize.func_id(mod, name, arity)

        with [_ | _] = sites <- Map.get(sinks, func_id, []),
             %Argus.Cfg.Function{} = cfg <- Helpers.cfg(module_data, name, arity) do
          entry = Map.get(entries, func_id, %{})
          bounds = Bounded.at(cfg, instrs, arity, Enum.map(sites, & &1.idx), entry, returns)

          correlated =
            for %{idx: idx, mfa: mfa} <- sites,
                ApiCalls.atom_sink?(mfa),
                not Map.has_key?(Map.get(bounds, idx, %{}), {:x, 0}),
                do: idx

          bounds =
            Map.merge(
              bounds,
              Bounded.correlated_at(cfg, instrs, arity, correlated, entry, returns),
              fn _idx, a, b ->
                Map.merge(b, a)
              end
            )

          for %{idx: idx, mfa: {_m, _f, sink_arity} = mfa} <- sites,
              pos <- 0..(sink_arity - 1)//1,
              {:ok, bound} <- [Map.fetch(Map.get(bounds, idx, %{}), {:x, pos})],
              not match?({:atoms, _}, bound) or ApiCalls.atom_sink?(mfa),
              reduce: acc do
            inner ->
              add_fact(inner, :sink_arg_bounded, [
                InstrId.mint(func_id, idx),
                func_id,
                to_string(pos),
                list_param(bound)
              ])
          end
        else
          _ -> acc
        end
      end)

    emit_sequence_bounds(facts, module_data, sinks)
  end

  # A successful list-to-atom conversion rejects non-character elements. Keep
  # this vocabulary proof specific to that operation; a numeric range alone
  # does not make arbitrary floating-point values finite.
  defp emit_sequence_bounds(facts, module_data, sinks) do
    finite =
      MapSet.new(for [id, _func, "0", ""] <- Map.get(facts, :sink_arg_bounded, []), do: id)

    candidates =
      for sites <- Map.values(sinks),
          %{func_id: func, idx: idx, mfa: {:erlang, :list_to_atom, 1}} = site <- sites,
          not MapSet.member?(finite, InstrId.mint(func, idx)),
          do: site

    module_data
    |> SequenceBounds.bounded_sites(candidates)
    |> Enum.reduce(facts, fn {func, idx}, acc ->
      add_fact(acc, :sink_arg_bounded, [InstrId.mint(func, idx), func, "0", ""])
    end)
  end

  # Sink calls of one API on one source line of one function, past the
  # first: the compiler's copies of one call.
  defp emit_sink_copies(facts, %{module: mod, functions: functions} = module_data, inputs) do
    line_table = Map.get(module_data, :line_table, %{})

    tuples =
      Map.new(functions, fn {:function, n, a, _e, instrs} ->
        {Normalize.func_id(mod, n, a), List.to_tuple(instrs)}
      end)

    module_data
    |> CallSites.for_module()
    |> Enum.filter(&ApiCalls.sink?(&1.mfa))
    |> Enum.group_by(fn %{func_id: f, idx: idx, mfa: mfa} ->
      {f, mfa, line_before(Map.fetch!(tuples, f), idx, line_table)}
    end)
    |> Enum.reduce(facts, fn
      {{_f, _mfa, nil}, _sites}, acc ->
        acc

      {{_f, _mfa, _line}, [_one]}, acc ->
        acc

      {{f, {_m, _fun, arity}, _line}, sites}, acc ->
        [first | rest] = Enum.sort_by(sites, & &1.idx)
        derived = &sink_inputs(inputs, f, &1.idx, arity)
        fun = fn -> cfg_of(module_data, f) end

        rest
        |> Enum.filter(&(derived.(&1) == derived.(first) or exclusive?(fun, first.idx, &1.idx)))
        |> Enum.reduce(acc, fn %{idx: idx}, inner ->
          add_fact(inner, :sink_copy, [InstrId.mint(f, idx), f, InstrId.mint(f, first.idx)])
        end)
    end)
  end

  # What each argument of the sink call at `idx` is derived from.
  defp sink_inputs(inputs, func_id, idx, arity) do
    site_inputs = inputs_at(inputs, func_id, idx)
    for pos <- 0..(arity - 1)//1, do: Map.get(site_inputs, "x#{pos}", MapSet.new())
  end

  # Two sites no trip through the function makes both of: a compiler's
  # copies of one expression into branches that exclude each other.
  defp exclusive?(fun, a, b) do
    case fun.() do
      nil ->
        false

      graph ->
        not CfgFunction.precedes?(graph, a, b) and not CfgFunction.precedes?(graph, b, a)
    end
  end

  defp cfg_of(module_data, func_id) do
    {name, arity} = Normalize.func_id_name_arity(func_id)
    Helpers.cfg(module_data, name, arity)
  end

  # The source line in effect at `idx`: the nearest line marker before it.
  defp line_before(tuple, idx, line_table) do
    Enum.find_value((idx - 1)..0//-1, fn i ->
      case elem(tuple, i) do
        {:line, marker} -> Disassemble.marker_line(marker, line_table)
        _other -> nil
      end
    end)
  end

  defp list_param({:values, _n}), do: ""
  defp list_param({:atoms, _n}), do: "atoms"
  defp list_param({:param, q}), do: to_string(q)

  # The positions at which every call from a function to a callee passes
  # a literal list: the list is moved into the argument register in the
  # run of instructions before the call.
  defp emit_allowlists(facts, %{module: mod, functions: functions} = module_data) do
    by_function =
      Map.new(functions, fn {:function, n, a, _e, instrs} ->
        {Normalize.func_id(mod, n, a), List.to_tuple(instrs)}
      end)

    module_data
    |> CallSites.for_module()
    |> Enum.group_by(fn %{func_id: f, mfa: {m, fun, a}} -> {f, Normalize.func_id(m, fun, a)} end)
    |> Enum.reduce(facts, fn {{caller, callee}, sites}, acc ->
      tuple = Map.fetch!(by_function, caller)
      {_m, _f, arity} = hd(sites).mfa

      Enum.reduce(0..(min(arity, @max_args) - 1)//1, acc, fn pos, inner ->
        if Enum.all?(sites, &literal_list_arg?(tuple, &1.idx, {:x, pos})),
          do: add_fact(inner, :call_arg_allowlist, [caller, callee, to_string(pos)]),
          else: inner
      end)
    end)
  end

  # The last write of `reg` before the call at `idx`, in the straight run
  # of instructions ending there, is a move of a literal list.
  defp literal_list_arg?(tuple, idx, reg) do
    Enum.reduce_while((idx - 1)..0//-1, false, fn i, false ->
      instr = elem(tuple, i)

      cond do
        match?({:label, _}, instr) -> {:halt, false}
        not Instr.falls_through?(instr) -> {:halt, false}
        Instr.clobbers?(instr, reg) -> {:halt, literal_list_move?(instr)}
        true -> {:cont, false}
      end
    end)
  end

  defp literal_list_move?({:move, {:literal, list}, _dst}) when is_list(list), do: list != []
  defp literal_list_move?(_instr), do: false

  # Compiler-created closures can place captured values beyond the first four
  # arguments. Preserve every position, including intermediate helpers, so data
  # flow does not depend on how many values a generated template captures.
  defp emit_call_arg(facts, prefix, derived, _pos) do
    Enum.reduce(derived, facts, fn
      :chosen, acc ->
        add_fact(acc, :call_arg_chosen, prefix)

      param, acc when is_integer(param) ->
        add_fact(acc, :call_arg_derived, prefix ++ [to_string(param)])

      _origin, acc ->
        acc
    end)
  end

  # A sink's every position, since the finding hangs on it.
  defp emit_sink_arg(facts, prefix, derived) do
    Enum.reduce(derived, facts, fn
      :chosen, acc ->
        add_fact(acc, :sink_arg_chosen, prefix)

      param, acc when is_integer(param) ->
        add_fact(acc, :sink_arg_derived, prefix ++ [to_string(param)])

      _origin, acc ->
        acc
    end)
  end
end
