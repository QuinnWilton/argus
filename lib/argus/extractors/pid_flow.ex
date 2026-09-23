defmodule Argus.Extractors.PidFlow do
  @moduledoc """
  Which process each pid a function handles can be: the per-function half of
  a points-to analysis whose objects are processes.

  A pid is a reference and the call that started the process is its
  allocation site: `spawn(M, F, args)` or `spawn(fun)` (named by what it
  runs, from `spawn_call`) and `GenServer.start/start_link` or
  `:gen_server`/`:gen_statem` starts with a literal module. The process
  registry is a heap field everyone shares: `register/2` stores a pid under
  a name, and a send to that name, or a `whereis` of it, loads it back.

  This extractor summarises, for every function, where the pids it passes
  on came from — a start in this function, one of its parameters, the
  result of a call into project code, or a registered name — and the
  Datalog in `clientlib/processes.dl` chains the summaries across
  functions, the way `clientlib/reach.dl` chains `call_arg_derived`.

  ## Emitted facts

  Sources are `{src_kind, src}`: `proc` (a process id, below), `param` (a
  parameter position), `result` (the callee whose return value it is),
  `name` (a registered name) or `self` (`self()`: which process that is
  depends on who runs the function, which the Datalog knows).

  - `process_start(func, proc, kind, runs)` — `func` starts the process
    `proc`: `kind` is `spawn` (`runs` is the function it runs) or `server`
    (`runs` is the callback module), including a child a supervisor starts
    on request (`DynamicSupervisor.start_child/2`, `Supervisor.start_child/2`),
    named by its child spec's module. Process ids are `"spawn Mod:fun/n"`
    and `"server Mod"`: function-level, so a body edit does not rename them.
  - `pid_arg(caller, callee, arg_pos, src_kind, src)` — at some call in
    `caller`, argument `arg_pos` may be a pid from the source. Also for a
    server start's init argument (the callback module's `init/1`), a spawn's
    single argument, and a closure's captured variables (its trailing
    parameters, as in `ParamFlow`).
  - `pid_return(func, src_kind, src)` — `func` may return a pid from the
    source, including by a tail call.
  - `pid_call(func, api_kind, src_kind, src)` — a GenServer-style `call` or
    `cast` in `func` (the `sync_call`/`async_cast` table) whose target may
    be a pid from the source.
  - `pid_register(func, name, src_kind, src)` — `func` registers a pid from
    the source under `name`.
  - `pid_send(id, func, message, src_kind, src)` — the send at `id` goes to
    a pid from the source, or to a literal name. `message` is the literal
    atom sent, `{:tag, …}` for a tuple with a literal atom first, or
    `dynamic`. Keyed on the site, because a finding anchors there.

  ## Reading the bytecode

  The same union fixpoint as `ParamFlow` over `Argus.Dataflow`'s reaching
  definitions, with process sources in place of parameter positions: a
  structural instruction derives what it writes from everything it reads;
  a start's result is its process; a call into project code yields
  `result`; `whereis` of a literal name yields `name`; `self()` yields
  `self`; any other call, a
  BIF outside the structural few, `call_fun` and `apply` yield nothing.
  What cannot be followed is lost rather than invented, so every rule on
  top of these facts stays quiet where it cannot be sure.

  Positions are symbols, not numbers, so the Datalog joins them to each
  other without the partial `to_number` functor.
  """

  @behaviour Argus.Extractor

  alias Argus.Dataflow
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ApiCalls
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [add_fact: 3, register: 1]

  @max_args 4

  # A fixpoint over a finite lattice converges; the bound only guards a bug.
  @max_passes 64

  # The callback module is x0 in the Elixir starts and in the anonymous
  # Erlang ones; x1 after the name in `start_link({:local, n}, mod, ...)`.
  @server_starts %{
    {GenServer, :start, 2} => 0,
    {GenServer, :start, 3} => 0,
    {GenServer, :start_link, 2} => 0,
    {GenServer, :start_link, 3} => 0,
    {:gen_server, :start, 3} => 0,
    {:gen_server, :start, 4} => 1,
    {:gen_server, :start_link, 3} => 0,
    {:gen_server, :start_link, 4} => 1,
    {:gen_statem, :start, 3} => 0,
    {:gen_statem, :start, 4} => 1,
    {:gen_statem, :start_link, 3} => 0,
    {:gen_statem, :start_link, 4} => 1
  }

  # A start through a supervisor returns the child's pid too; the child
  # spec in x1 names the module (`Mod`, `{Mod, arg}`, `%{start: {Mod, ...}}`).
  @child_starts [{DynamicSupervisor, :start_child, 2}, {Supervisor, :start_child, 2}]

  @lookups [{Process, :whereis, 1}, {:erlang, :whereis, 1}]

  @impl true
  def relations, do: [:process_start, :pid_arg, :pid_return, :pid_call, :pid_register, :pid_send]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    case Helpers.typed(module_data) do
      nil ->
        %{}

      typed ->
        sites = CallSites.for_module(module_data)
        starts = starts(typed, sites)
        values = derive(typed, starts, sites)

        %{}
        |> emit_starts(starts)
        |> emit_call_sites(sites, starts, values)
        |> emit_returns(typed, sites, starts, values)
        |> emit_send_opcodes(module_data, values)
        |> emit_closures(module_data, values)
        |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    end
  end

  # ── Allocation sites ─────────────────────────────────────────────────

  # %{instr_id => %{proc, kind, runs, arg}}: every start in the module, with
  # where the process's own first parameter comes from when it can be said.
  defp starts(typed, sites) do
    spawns =
      for %{mod: mod, func: fun, arity: arity} = row <- Map.get(typed, :spawn_call, []),
          mod != "dynamic",
          into: %{} do
        runs = "#{mod}:#{fun}/#{arity}"
        {row.id, %{proc: "spawn " <> runs, kind: "spawn", runs: runs, arity: arity}}
      end

    servers =
      for %{mfa: mfa, instrs: instrs, idx: idx, func_id: func_id} <- sites,
          {:ok, pos} <- [Map.fetch(@server_starts, mfa)],
          {:ok, mod} <- [Helpers.resolve_register(instrs, idx, {:x, pos})],
          is_atom(mod) and mod != :dynamic,
          into: %{} do
        runs = inspect(mod)

        {parse(InstrId.mint(func_id, idx)),
         %{proc: "server " <> runs, kind: "server", runs: runs, init_arg: pos + 1}}
      end

    children =
      for %{mfa: mfa, instrs: instrs, idx: idx, func_id: func_id} <- sites,
          mfa in @child_starts,
          {:ok, spec} <- [Helpers.resolve_register(instrs, idx, {:x, 1})],
          mod = child_module(spec),
          mod != nil and not library?(mod),
          into: %{} do
        runs = inspect(mod)

        {parse(InstrId.mint(func_id, idx)),
         %{proc: "server " <> runs, kind: "server", runs: runs, child: true}}
      end

    spawns |> Map.merge(servers) |> Map.merge(children)
  end

  defp child_module({mod, _arg}), do: child_module(mod)
  defp child_module(%{start: {mod, _fun, _args}}), do: child_module(mod)
  defp child_module(mod) when is_atom(mod) and mod not in [nil, :dynamic], do: mod
  defp child_module(_spec), do: nil

  # ── The fixpoint ─────────────────────────────────────────────────────

  # For every instruction, the sources each register it reads may hold:
  # %{id => %{reg => MapSet({kind, src})}}.
  defp derive(typed, starts, sites) do
    triples = Dataflow.reaching_uses(typed, params: true)

    reads =
      Enum.group_by(triples, fn {_source, _reg, use} -> use end, fn {source, reg, _use} ->
        {reg, source}
      end)

    writes = typed |> Map.get(:def, []) |> Enum.group_by(& &1.id, & &1.reg)
    ops = Map.new(Map.get(typed, :instruction, []), &{&1.id, &1.op})
    bifs = Map.new(Map.get(typed, :bif_call, []), &{&1.id, &1.func})
    tails = MapSet.new(Map.get(typed, :tail_call, []), & &1.id)

    ids =
      typed
      |> Map.get(:instruction, [])
      |> Enum.sort_by(&{&1.id.module, &1.id.func, &1.id.arity, &1.idx})
      |> Enum.map(& &1.id)

    ctx = %{
      reads: reads,
      writes: writes,
      ops: ops,
      bifs: bifs,
      tails: tails,
      calls: call_values(sites, starts),
      dynamics: MapSet.new(Map.get(typed, :dynamic_call, []), & &1.id)
    }

    outs = fixpoint(ids, ctx, %{}, 0)
    Map.new(ids, fn id -> {id, inputs_of(id, ctx, outs)} end)
  end

  # What each call writes to x0: a start's process, a lookup's name, a
  # project call's result, or nothing.
  defp call_values(sites, starts) do
    Map.new(sites, fn %{func_id: func_id, idx: idx, mfa: mfa, instrs: instrs} = site ->
      id = parse(InstrId.mint(func_id, idx))

      value =
        cond do
          Map.has_key?(starts, id) -> MapSet.new([{"proc", starts[id].proc}])
          mfa in @lookups -> lookup(instrs, idx)
          project?(site) -> MapSet.new([{"result", callee(mfa)}])
          true -> MapSet.new()
        end

      {id, value}
    end)
  end

  defp lookup(instrs, idx) do
    case Helpers.resolve_atom(instrs, idx, {:x, 0}) do
      "dynamic" -> MapSet.new()
      name -> MapSet.new([{"name", name}])
    end
  end

  defp fixpoint(ids, ctx, outs, pass) when pass < @max_passes do
    {outs, changed?} =
      Enum.reduce(ids, {outs, false}, fn id, {acc, changed?} ->
        inputs = inputs_of(id, ctx, acc)
        all_inputs = inputs |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

        Enum.reduce(Map.get(ctx.writes, id, []), {acc, changed?}, fn reg,
                                                                     {inner, inner_changed?} ->
          derived = transfer(id, reg, inputs, all_inputs, ctx)
          previous = Map.get(inner, {id, reg}, MapSet.new())

          if MapSet.equal?(derived, previous),
            do: {inner, inner_changed?},
            else: {Map.put(inner, {id, reg}, derived), true}
        end)
      end)

    if changed?, do: fixpoint(ids, ctx, outs, pass + 1), else: outs
  end

  defp fixpoint(_ids, _ctx, outs, _pass), do: outs

  defp inputs_of(id, ctx, outs) do
    ctx.reads
    |> Map.get(id, [])
    |> Enum.group_by(fn {reg, _source} -> reg end, fn {_reg, source} -> source end)
    |> Map.new(fn {reg, sources} ->
      derived =
        Enum.reduce(sources, MapSet.new(), fn
          {:param, k}, acc ->
            MapSet.put(acc, {"param", Integer.to_string(k)})

          %InstrId{} = source, acc ->
            MapSet.union(acc, Map.get(outs, {source, reg}, MapSet.new()))
        end)

      {reg, derived}
    end)
  end

  defp transfer(id, reg, inputs, all_inputs, ctx) do
    cond do
      MapSet.member?(ctx.tails, id) ->
        MapSet.new()

      Map.has_key?(ctx.calls, id) ->
        if reg == "x0", do: Map.fetch!(ctx.calls, id), else: MapSet.new()

      MapSet.member?(ctx.dynamics, id) ->
        MapSet.new()

      Map.get(ctx.bifs, id) == "self" ->
        MapSet.new([{"self", "self"}])

      Map.has_key?(ctx.bifs, id) ->
        if Propagators.bif?(Map.fetch!(ctx.bifs, id)), do: all_inputs, else: MapSet.new()

      Map.get(ctx.ops, id) in ~w(make_fun3 call_fun call_fun2 apply apply_last) ->
        MapSet.new()

      Map.get(ctx.ops, id) == "swap" ->
        ctx.writes
        |> Map.fetch!(id)
        |> Enum.reject(&(&1 == reg))
        |> then(&union_of(inputs, &1))

      true ->
        all_inputs
    end
  end

  defp union_of(inputs, regs) do
    Enum.reduce(regs, MapSet.new(), fn reg, acc ->
      MapSet.union(acc, Map.get(inputs, reg, MapSet.new()))
    end)
  end

  # ── Emission ─────────────────────────────────────────────────────────

  defp emit_starts(facts, starts) do
    Enum.reduce(starts, facts, fn {id, start}, acc ->
      func_id = InstrId.func_id(id.module, id.func, id.arity)
      add_fact(acc, :process_start, [func_id, start.proc, start.kind, start.runs])
    end)
  end

  defp emit_call_sites(facts, sites, starts, values) do
    Enum.reduce(sites, facts, fn %{func_id: func_id, idx: idx, mfa: mfa, instrs: instrs} = site,
                                 acc ->
      id = parse(InstrId.mint(func_id, idx))
      at = Map.get(values, id, %{})

      acc
      |> emit_args(site, at)
      |> emit_start_args(func_id, Map.get(starts, id), at)
      |> emit_process_call(func_id, mfa, at)
      |> emit_register(func_id, mfa, instrs, idx, at)
      |> emit_send(func_id, id, mfa, instrs, idx, at)
    end)
  end

  defp emit_args(facts, %{func_id: func_id, mfa: {_m, _f, arity} = mfa} = site, at) do
    if project?(site) do
      Enum.reduce(0..(min(arity, @max_args) - 1)//1, facts, fn pos, acc ->
        emit_sources(acc, :pid_arg, [func_id, callee(mfa), to_string(pos)], at["x#{pos}"])
      end)
    else
      facts
    end
  end

  # A server's init/1 receives the start's init argument; a process spawned
  # to run a one-argument function receives the single element of its list.
  defp emit_start_args(facts, func_id, %{kind: "server", runs: mod, init_arg: pos}, at),
    do: emit_sources(facts, :pid_arg, [func_id, "#{mod}:init/1", "0"], at["x#{pos}"])

  # A child spec `{Mod, arg}` starts `Mod.start_link(arg)`; the spec is
  # not taken apart, so a pid anywhere in it counts as the argument.
  defp emit_start_args(facts, func_id, %{kind: "server", runs: mod, child: true}, at),
    do: emit_sources(facts, :pid_arg, [func_id, "#{mod}:start_link/1", "0"], at["x1"])

  defp emit_start_args(facts, func_id, %{kind: "spawn", runs: runs, arity: 1}, at),
    do: emit_sources(facts, :pid_arg, [func_id, runs, "0"], at["x2"])

  defp emit_start_args(facts, _func_id, _start, _at), do: facts

  defp emit_process_call(facts, func_id, mfa, at) do
    case ApiCalls.process_call_kind(mfa) do
      nil -> facts
      kind -> emit_sources(facts, :pid_call, [func_id, to_string(kind)], at["x0"])
    end
  end

  defp emit_register(facts, func_id, {Process, :register, 2}, instrs, idx, at),
    do: register_row(facts, func_id, Helpers.resolve_atom(instrs, idx, {:x, 1}), at["x0"])

  defp emit_register(facts, func_id, {:erlang, :register, 2}, instrs, idx, at),
    do: register_row(facts, func_id, Helpers.resolve_atom(instrs, idx, {:x, 0}), at["x1"])

  defp emit_register(facts, _func_id, _mfa, _instrs, _idx, _at), do: facts

  defp register_row(facts, _func_id, "dynamic", _sources), do: facts

  defp register_row(facts, func_id, name, sources),
    do: emit_sources(facts, :pid_register, [func_id, name], sources)

  defp emit_send(facts, func_id, id, {mod, :send, arity}, instrs, idx, at)
       when (mod == :erlang and arity in [2, 3]) or (mod == Process and arity == 3),
       do: send_row(facts, func_id, id, instrs, idx, at)

  defp emit_send(facts, _func_id, _id, _mfa, _instrs, _idx, _at), do: facts

  # The send opcode (Erlang's `!`) is not a call site.
  defp emit_send_opcodes(facts, %{module: mod, functions: functions}, values) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn
        {:send, idx}, inner ->
          id = parse(InstrId.mint(func_id, idx))
          send_row(inner, func_id, id, instrs, idx, Map.get(values, id, %{}))

        _other, inner ->
          inner
      end)
    end)
  end

  defp send_row(facts, func_id, id, instrs, idx, at) do
    destination =
      case Helpers.resolve_atom(instrs, idx, {:x, 0}) do
        "dynamic" -> Map.get(at, "x0", MapSet.new())
        name -> MapSet.put(Map.get(at, "x0", MapSet.new()), {"name", name})
      end

    emit_sources(
      facts,
      :pid_send,
      [InstrId.format(id), func_id, message(instrs, idx)],
      destination
    )
  end

  # The message as a receive pattern would read it: a literal atom, a
  # tuple's literal atom tag, or unknown.
  defp message(instrs, idx) do
    case Helpers.resolve_register(instrs, idx, {:x, 1}) do
      {:ok, atom} when is_atom(atom) and atom != :dynamic ->
        inspect(atom)

      {:ok, tuple} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        case elem(tuple, 0) do
          tag when is_atom(tag) and tag != :dynamic -> "{#{inspect(tag)}, …}"
          _ -> "dynamic"
        end

      _ ->
        "dynamic"
    end
  end

  # What a function returns: x0 at each `return`, and the callee's result
  # (or the started process) at each tail call.
  defp emit_returns(facts, typed, sites, starts, values) do
    returned =
      for %{id: id, op: "return"} <- Map.get(typed, :instruction, []), reduce: facts do
        acc ->
          func_id = InstrId.func_id(id.module, id.func, id.arity)
          emit_sources(acc, :pid_return, [func_id], get_in(values, [id, "x0"]))
      end

    tails = MapSet.new(Map.get(typed, :tail_call, []), & &1.id)

    Enum.reduce(sites, returned, fn %{func_id: func_id, idx: idx, mfa: mfa} = site, acc ->
      id = parse(InstrId.mint(func_id, idx))

      cond do
        not MapSet.member?(tails, id) or generated?(func_id) ->
          acc

        Map.has_key?(starts, id) ->
          add_fact(acc, :pid_return, [func_id, "proc", starts[id].proc])

        project?(site) ->
          add_fact(acc, :pid_return, [func_id, "result", callee(mfa)])

        true ->
          acc
      end
    end)
  end

  # A closure's environment is its trailing parameters (as in ParamFlow):
  # a pid captured by `spawn(fn -> send(parent, ...) end)` reaches the body.
  defp emit_closures(facts, %{module: mod, functions: functions}, values) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      func_id = Normalize.func_id(mod, name, arity)

      instrs
      |> Enum.with_index()
      |> Enum.reduce(acc, fn
        {{:make_fun3, {cmod, cname, carity}, _index, _uniq, _dst, {:list, env}}, idx}, inner ->
          at = Map.get(values, parse(InstrId.mint(func_id, idx)), %{})
          closure = Normalize.func_id(cmod, cname, carity)
          first = carity - length(env)

          env
          |> Enum.with_index()
          |> Enum.reduce(inner, fn {operand, slot}, deep ->
            case register(operand) do
              {kind, n} when kind in [:x, :y] ->
                emit_sources(
                  deep,
                  :pid_arg,
                  [func_id, closure, to_string(first + slot)],
                  at["#{kind}#{n}"]
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

  defp emit_sources(facts, _relation, _prefix, nil), do: facts

  # The compiler's own module_info/__info__ functions pass nothing a
  # process analysis needs.
  defp emit_sources(facts, relation, [func | _] = prefix, sources) do
    if generated?(func), do: facts, else: emit_each(facts, relation, prefix, sources)
  end

  defp emit_each(facts, relation, prefix, sources) do
    Enum.reduce(sources, facts, fn {kind, src}, acc ->
      emit_row(acc, relation, prefix ++ [kind, src])
    end)
  end

  # One literal add_fact per relation, so the relation list stays
  # checkable against the source.
  defp emit_row(facts, :pid_arg, row), do: add_fact(facts, :pid_arg, row)
  defp emit_row(facts, :pid_return, row), do: add_fact(facts, :pid_return, row)
  defp emit_row(facts, :pid_call, row), do: add_fact(facts, :pid_call, row)
  defp emit_row(facts, :pid_register, row), do: add_fact(facts, :pid_register, row)
  defp emit_row(facts, :pid_send, row), do: add_fact(facts, :pid_send, row)

  # ── Which calls reach project code ───────────────────────────────────

  # A local call, or a remote call into a module that is not part of OTP or
  # Elixir itself: the only callees whose own summaries can say what they
  # do with a pid. Library calls are neither followed nor recorded, which
  # keeps the relations to the program's own code.
  defp project?(%{remote?: false}), do: true
  defp project?(%{mfa: {mod, _f, _a}}), do: not library?(mod)

  defp library?(mod) do
    case :code.which(mod) do
      # erlang, erts_internal and the rest of the VM's own modules.
      :preloaded ->
        true

      path when is_list(path) ->
        path = List.to_string(path)
        Enum.any?(library_roots(), &String.starts_with?(path, &1))

      _ ->
        false
    end
  end

  defp library_roots do
    case :persistent_term.get({__MODULE__, :roots}, nil) do
      nil ->
        roots = [List.to_string(:code.root_dir()), elixir_root()]
        :persistent_term.put({__MODULE__, :roots}, roots)
        roots

      roots ->
        roots
    end
  end

  # Elixir's own applications (elixir, logger, mix, ...) sit side by side.
  defp elixir_root do
    :elixir |> :code.lib_dir() |> List.to_string() |> Path.dirname()
  end

  defp generated?(func_id) do
    String.contains?(func_id, [":__info__/", ":module_info/", ":-inlined-"])
  end

  defp callee({mod, fun, arity}), do: Normalize.func_id(mod, fun, arity)

  defp parse(id) do
    {:ok, instr_id} = InstrId.parse(id)
    instr_id
  end
end
