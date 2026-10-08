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
  - `site_reads(site, func, kind, source)`, `call_arg_reads(caller,
    callee, arg_pos, kind, source)` and `returns_reads(func, kind, source)`
    — the same questions by data alone: what the operation's, the
    argument's or the returned value is made of, not what it runs under. A check-then-act race that writes back what it read is a
    lost update; one whose write only runs because of the read, with a
    value from elsewhere, may be a refill both racers agree on.
  - `sink_reads(site, func, arg_pos, kind, source)` — what argument
    `arg_pos` of the sink call at `site` (`Argus.Extractors.ApiCalls.
    sink_mfas/0`: atom creation, deserialization, code execution) is made
    of, by data alone. The runtime's calls on the way carry their
    arguments through, where ParamFlow's `sink_arg_derived` follows only
    the propagators it lists: `String.to_atom(Macro.underscore(name))` is
    made of `name` here and of nothing there.
  - `field_decides(func, kind, source, pos)` — a test in the function
    decides on element `pos` of a tuple the source holds (a
    `get_tuple_element`, or `element/2` with a literal index), or on a
    value made from one. A check that decides only whether a lookup found
    a row tests no element; `[{^k, cur}] when cur >= serial` tests the
    row's key (element 0) and its value (element 1). An
    `:ets.lookup_element/3` answer is element 1 of its row.
  - `field_compared(func, kind, source, pos, other_kind, other_source)` —
    what a comparison (a test, or a comparison BIF) compares element `pos`
    of the source's tuple with: the other operand's sources, by data
    alone, that the element is not made of itself. `cur >= serial`
    compares element 1 of the row with parameter 1; `blocked > now`, a
    clock read, has no row. The control half is left out: every value
    under a key match would otherwise be compared with the key.
  - `effect_decided(func, kind, source)` — a message send, or a runtime
    call that changes something outside the function
    (`Argus.Purity.Effects`: a process, a port, a file, the network, a
    node; logging, clocks, randomness and the process dictionary are not
    counted), runs only because of a test on the source. The runtime's
    calls are otherwise not emitted (below); a project call under a
    decision is `call_decided`'s.

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

  By data alone (the `*_reads` relations), a lookup of the environment,
  the application's configuration, a persistent term or the process
  dictionary is made of its default, not of its key: `System.get_env(name)`
  answers what the environment holds, which a caller naming the variable
  does not choose.

  By data alone, too, the position a counted closure reads out of the
  pair it is handed (`for {t, i} <- Enum.with_index(ts, 1)`) is a counter
  made of nothing the closure was handed (`ParamFlow.Counters`).

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
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Runtime
  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.ApiCalls
  alias Argus.Extractors.ETS
  alias Argus.Extractors.Mnesia
  alias Argus.Extractors.ParamFlow.Counters
  alias Argus.Extractors.ProcessRegistry
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Purity.Effects

  import Argus.Instr, only: [register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3]

  # A fixpoint over a finite lattice converges; the bound only guards a bug.
  @max_evaluations 64

  @typep source :: {:param, non_neg_integer()} | {:call, String.t()} | {:site, String.t()}
  @typep field :: {:field, non_neg_integer(), source()}
  @typep deps :: MapSet.t(source() | field())

  @impl true
  def relations,
    do: [
      :call_arg_depends,
      :call_arg_reads,
      :call_decided,
      :effect_decided,
      :field_compared,
      :field_decides,
      :returns_depends,
      :returns_reads,
      :site_depends,
      :site_reads,
      :sink_reads
    ]

  @doc """
  Whether a remote call is a shared-state operation: a read or a write of
  the process registry, an ETS table or a Mnesia table, as each family's
  extractor defines it.
  """
  @spec site?(mfa()) :: boolean()
  def site?(mfa),
    do:
      ProcessRegistry.site?(mfa) or ETS.site?(mfa) or Mnesia.site?(mfa) or
        Argus.Extractors.SharedStore.site?(mfa)

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    with typed when typed != nil <- Helpers.typed(module_data),
         reaching when reaching != nil <- Helpers.reaching(module_data) do
      index = index(module_data, typed, reaching)
      # Extracted one function at a time, the module's counted closures
      # come with the function (Argus.Graph.Captures).
      counted =
        Map.get_lazy(module_data, :counted_closures, fn -> Counters.closures(module_data) end)

      module_data.functions
      |> Enum.reduce(%{}, fn {:function, name, arity, _entry, instrs}, acc ->
        func_id = InstrId.func_id(module_data.module, name, arity)

        case Helpers.cfg(module_data, name, arity) do
          nil ->
            acc

          fun ->
            shapes =
              instrs
              |> shapes()
              |> Map.put(:counters, Counters.projections(instrs, Map.get(counted, func_id)))

            function_facts(acc, func_id, fun, function_index(index, func_id), shapes)
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
            do: {idx, {InstrId.func_id(cmod, cname, carity), carity - length(env), env}}

      {InstrId.func_id(mod, name, arity), sites}
    end
  end

  # The instructions whose shape the flow asks about beyond what they read
  # and write: %{elements: %{idx => n}} for a projection of tuple element
  # n (from 0), %{sends: MapSet} for the sends, and %{comparisons: %{idx =>
  # [operand]}} for a test or a BIF comparing two terms.
  @compare_tests [:is_lt, :is_ge, :is_eq, :is_ne, :is_eq_exact, :is_ne_exact]
  @compare_bifs [:<, :>, :"=<", :>=, :==, :"/=", :"=:=", :"=/="]

  defp shapes(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(%{elements: %{}, sends: MapSet.new(), comparisons: %{}}, fn {instr, idx},
                                                                               acc ->
      case instr do
        {:test, op, _fail, [_a, _b] = operands} when op in @compare_tests ->
          put_in(acc, [:comparisons, idx], operands)

        {:bif, op, _fail, [_a, _b] = operands, _dst} when op in @compare_bifs ->
          put_in(acc, [:comparisons, idx], operands)

        {:get_tuple_element, _src, n, _dst} when is_integer(n) ->
          put_in(acc, [:elements, idx], n)

        {:bif, :element, _fail, [{:integer, n}, _src], _dst} when n >= 1 ->
          put_in(acc, [:elements, idx], n - 1)

        {:gc_bif, :element, _fail, _live, [{:integer, n}, _src], _dst} when n >= 1 ->
          put_in(acc, [:elements, idx], n - 1)

        :send ->
          %{acc | sends: MapSet.put(acc.sends, idx)}

        _other ->
          acc
      end
    end)
    |> Map.put(:row_keys, row_keys(instrs))
  end

  # The projections of a row's key out of a row a read found:
  # %{idx => {read_idx, key_register}}. The key of an ETS row
  # `:ets.lookup(t, k)` returned (element 0) and of a Mnesia record
  # `:mnesia.dirty_read(t, k)` returned (element 1) is the key the read
  # was asked for, and carries what the key carries, not what the table
  # held: `[{^k, _}] -> :ets.delete(t, k)`, whose compiler may hand the
  # delete the row's element, deletes the row it was asked for
  # (Argus.Extractor.Identity reads the key the same way).
  defp row_keys(instrs) do
    for {instr, idx} <- Enum.with_index(instrs),
        {src, n} <- projection(instr),
        {:ok, read} <- [row_read(instrs, idx, src, n)],
        into: %{},
        do: {idx, read}
  end

  defp projection({:get_tuple_element, src, n, _dst}) when is_integer(n), do: [{src, n}]

  defp projection({:bif, :element, _fail, [{:integer, n}, src], _dst}) when n >= 1,
    do: [{src, n - 1}]

  defp projection({:gc_bif, :element, _fail, _live, [{:integer, n}, src], _dst}) when n >= 1,
    do: [{src, n - 1}]

  defp projection(_instr), do: []

  defp row_read(instrs, idx, src, n) do
    Resolve.trace(instrs, idx, src, :no, fn
      {at, {:get_list, list, _hd, _tl}}, _follow -> read_of(instrs, at, list, n)
      {at, {:get_hd, list, _dst}}, _follow -> read_of(instrs, at, list, n)
      _writer, _follow -> :no
    end)
  end

  defp read_of(instrs, at, list, n) do
    Resolve.trace(instrs, at, list, :no, fn
      {call_at, instr}, _follow ->
        case {Helpers.match_remote_call(instr), n} do
          {{:ok, :ets, :lookup, 2}, 0} -> {:ok, {call_at, "x1"}}
          {{:ok, :mnesia, :dirty_read, 2}, 1} -> {:ok, {call_at, "x1"}}
          _ -> :no
        end

      _writer, _follow ->
        :no
    end)
  end

  # ── One function ────────────────────────────────────────────────────

  defp function_facts(facts, func_id, %CfgFunction{} = fun, index, shapes) do
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
      shapes: shapes,
      block_of: block_of,
      deciders: deciders,
      decider_of: decider_of(fun, deciders),
      decided: decided(fun, deciders)
    }

    {outs, tested} = solve(idxs, ctx)
    facts = Enum.reduce(idxs, facts, &emit(&2, &1, ctx, outs, tested))
    facts = emit_field_decisions(facts, func_id, tested)

    # The same flow with no decision counted: what an argument is made
    # of, as opposed to what it runs under.
    data_ctx = Map.merge(ctx, %{deciders: %{}, decider_of: %{}, decided: %{}, data: true})
    {data_outs, _} = solve(idxs, data_ctx)
    facts = Enum.reduce(idxs, facts, &emit_reads(&2, &1, data_ctx, data_outs))
    emit_field_compares(facts, func_id, data_ctx, data_outs)
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
              do: {reg, result(idx, reg, inputs, here, ctx, outs)}

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
  defp result(idx, reg, inputs, here, ctx, outs \\ %{}) do
    base =
      case {Map.fetch(ctx.index.calls, idx), Map.fetch(ctx.index.copies, idx)} do
        {{:ok, call}, _copy} ->
          call_result(idx, call, inputs, ctx)

        {:error, {:ok, copy}} ->
          copied(copy, reg, inputs)

        {:error, :error} ->
          case Map.fetch(ctx.shapes.row_keys, idx) do
            {:ok, {read, key}} ->
              read |> inputs_of(ctx, outs) |> Map.get(key, MapSet.new())

            :error ->
              if Map.get(ctx, :data, false) and MapSet.member?(ctx.shapes.counters, idx),
                do: MapSet.new(),
                else: union(inputs) |> element_of(Map.get(ctx.shapes.elements, idx))
          end
      end

    MapSet.union(base, here)
  end

  # A projection of element n: what the tuple depends on, and, for each
  # source the tuple is made of, element n of it — the fields a test can
  # decide on. Only a source's own elements are tagged; an element of an
  # element is still made from the field it was taken out of.
  defp element_of(deps, nil), do: deps

  defp element_of(deps, n) do
    Enum.reduce(deps, deps, fn
      {:field, _n, _source}, acc -> acc
      source, acc -> MapSet.put(acc, {:field, n, source})
    end)
  end

  defp call_result(idx, {{mod, fun, arity} = mfa, remote?}, inputs, ctx) do
    cond do
      not remote? -> MapSet.new([{:call, InstrId.func_id(mod, fun, arity)}])
      site?(mfa) -> site_result(mfa, InstrId.mint(ctx.func_id, idx), inputs)
      runtime?(mod) and Map.get(ctx, :data, false) -> lookup_result(mfa, inputs)
      runtime?(mod) -> union(inputs)
      true -> MapSet.put(union(inputs), {:call, InstrId.func_id(mod, fun, arity)})
    end
  end

  # By data alone, a read of the environment, the application's
  # configuration, a persistent term or the process dictionary answers
  # what is stored under its key, which is not made of the key:
  # `System.get_env(name)` is not made of `name`. It is made of its
  # default, where it takes one. Every other runtime call's result is
  # made of its arguments. Under a decision the key still counts: which
  # value comes back depends on it.
  @lookups %{
    {System, :get_env, 1} => nil,
    {System, :get_env, 2} => 1,
    {System, :fetch_env, 1} => nil,
    {System, :fetch_env!, 1} => nil,
    {:os, :getenv, 1} => nil,
    {:os, :getenv, 2} => 1,
    {Application, :get_env, 2} => nil,
    {Application, :get_env, 3} => 2,
    {Application, :fetch_env, 2} => nil,
    {Application, :fetch_env!, 2} => nil,
    {Application, :get_all_env, 1} => nil,
    {:application, :get_env, 1} => nil,
    {:application, :get_env, 2} => nil,
    {:application, :get_env, 3} => 2,
    {:application, :get_all_env, 1} => nil,
    {:persistent_term, :get, 1} => nil,
    {:persistent_term, :get, 2} => 1,
    {Process, :get, 1} => nil,
    {Process, :get, 2} => 1,
    {:erlang, :get, 1} => nil
  }

  defp lookup_result(mfa, inputs) do
    case Map.fetch(@lookups, mfa) do
      {:ok, nil} -> MapSet.new()
      {:ok, default} -> Map.get(inputs, "x#{default}", MapSet.new())
      :error -> union(inputs)
    end
  end

  # A shared-state operation's result: the site. What `:ets.lookup_element`
  # answers is already a field of the row, element 1 of it.
  defp site_result({:ets, :lookup_element, _arity}, site, inputs),
    do: inputs |> union() |> MapSet.put({:site, site}) |> MapSet.put({:field, 1, {:site, site}})

  defp site_result(_mfa, site, inputs), do: inputs |> union() |> MapSet.put({:site, site})

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
    |> emit_send(MapSet.member?(ctx.shapes.sends, idx), here, ctx)
    |> emit_closure(Map.get(ctx.index.closures, idx), inputs, here, ctx)
    |> emit_return(idx, inputs, here, ctx)
  end

  defp emit_send(facts, false, _here, _ctx), do: facts
  defp emit_send(facts, true, here, ctx), do: rows(facts, :effect_decided, [ctx.func_id], here)

  # What each comparison compares a tuple's element with: for an operand
  # holding element n of a source, the sources of the other operand that
  # the first is not made of itself (a lookup's row is made of the key it
  # was asked for; comparing the row's value is not comparing it with the
  # key), by data alone.
  defp emit_field_compares(facts, func_id, data_ctx, data_outs) do
    for {idx, operands} <- data_ctx.shapes.comparisons,
        inputs = ValueFlow.inputs(data_ctx.index.reads, data_outs, idx, &{:param, &1}),
        deps = Enum.map(operands, &operand_deps(inputs, &1)),
        {mine, i} <- Enum.with_index(deps),
        {theirs, j} <- Enum.with_index(deps),
        i != j,
        {:field, n, source} <- mine,
        other <- theirs,
        base?(other),
        not MapSet.member?(mine, other),
        reduce: facts do
      acc ->
        add_fact(
          acc,
          :field_compared,
          [func_id | encode(source)] ++ [to_string(n) | encode(other)]
        )
    end
  end

  defp operand_deps(inputs, operand) do
    case Instr.register(operand) do
      {kind, n} when kind in [:x, :y] -> Map.get(inputs, "#{kind}#{n}", MapSet.new())
      _literal -> MapSet.new()
    end
  end

  defp base?({:field, _n, _source}), do: false
  defp base?(_source), do: true

  # Every element a decision tests, by the source whose tuple it is.
  defp emit_field_decisions(facts, func_id, tested) do
    for {_decider, decision} <- tested,
        {:field, n, source} <- decision,
        reduce: facts do
      acc -> add_fact(acc, :field_decides, [func_id | encode(source)] ++ [to_string(n)])
    end
  end

  defp emit_call(facts, nil, _idx, _inputs, _here, _ctx), do: facts

  defp emit_call(facts, {{mod, fun, arity} = mfa, remote?}, idx, inputs, here, ctx) do
    cond do
      remote? and site?(mfa) ->
        site = InstrId.mint(ctx.func_id, idx)
        rows(facts, :site_depends, [site, ctx.func_id], MapSet.union(here, union(inputs)))

      remote? and runtime?(mod) ->
        if effect?(mfa), do: rows(facts, :effect_decided, [ctx.func_id], here), else: facts

      true ->
        callee = InstrId.func_id(mod, fun, arity)
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

  # The data-only rows: a site's arguments and a call's, and what the
  # function returns, by what they are made of. Closures are not followed
  # here: a captured value is made of what the closure body does with it,
  # which is the closure's own function's question.
  defp emit_reads(facts, idx, ctx, outs) do
    facts
    |> emit_call_reads(idx, ctx, outs)
    |> emit_return_reads(idx, ctx, outs)
  end

  defp emit_return_reads(facts, idx, ctx, outs) do
    cond do
      Map.has_key?(ctx.index.tails, idx) ->
        inputs = inputs_of(idx, ctx, outs)

        rows(
          facts,
          :returns_reads,
          [ctx.func_id],
          result(idx, "x0", inputs, MapSet.new(), ctx, outs)
        )

      Map.get(ctx.index.ops, idx) == "return" ->
        inputs = inputs_of(idx, ctx, outs)
        rows(facts, :returns_reads, [ctx.func_id], Map.get(inputs, "x0", MapSet.new()))

      true ->
        facts
    end
  end

  defp emit_call_reads(facts, idx, ctx, outs) do
    case Map.get(ctx.index.calls, idx) do
      nil ->
        facts

      {{mod, fun, arity} = mfa, remote?} ->
        inputs = inputs_of(idx, ctx, outs)

        facts = emit_sink_reads(facts, remote? and ApiCalls.sink?(mfa), idx, arity, inputs, ctx)

        cond do
          remote? and site?(mfa) ->
            site = InstrId.mint(ctx.func_id, idx)
            rows(facts, :site_reads, [site, ctx.func_id], union(inputs))

          remote? and runtime?(mod) ->
            facts

          true ->
            callee = InstrId.func_id(mod, fun, arity)

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

  # A sink's arguments, by what they are made of: the runtime's calls on
  # the way carry their arguments through (`String.to_atom(
  # Macro.underscore(name))` is made of `name`), where ParamFlow follows
  # only the propagators it lists.
  defp emit_sink_reads(facts, false, _idx, _arity, _inputs, _ctx), do: facts

  defp emit_sink_reads(facts, true, idx, arity, inputs, ctx) do
    site = InstrId.mint(ctx.func_id, idx)

    Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
      rows(
        acc,
        :sink_reads,
        [site, ctx.func_id, to_string(pos)],
        Map.get(inputs, "x#{pos}", MapSet.new())
      )
    end)
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

  # A runtime call that changes something outside the function. Logging,
  # clocks, randomness and the process dictionary change nothing another
  # process or the outside world acts on; ETS and Mnesia are sites.
  @quiet_effects [:logging, :time, :random, :process_dict, :ets]

  defp effect?({mod, fun, _arity}) do
    case Effects.classify(inspect(mod), to_string(fun)) do
      {:impure, category, :write} -> category not in @quiet_effects
      _other -> false
    end
  end

  # A field tag is flow-internal: every relation but field_decides names
  # the sources themselves.
  defp rows(facts, relation, prefix, deps) do
    Enum.reduce(deps, facts, fn
      {:field, _n, _source}, acc -> acc
      source, acc -> add_fact(acc, relation, prefix ++ encode(source))
    end)
  end

  defp encode({:param, k}), do: ["param", to_string(k)]
  defp encode({:call, callee}), do: ["call", callee]
  defp encode({:site, site}), do: ["site", site]
end
