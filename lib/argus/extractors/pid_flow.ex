defmodule Argus.Extractors.PidFlow do
  @moduledoc """
  Which process each pid a function handles can be: the per-function half of
  a points-to analysis whose objects are processes and the terms that hold
  them.

  A pid is a reference and the call that started the process is its
  allocation site: a spawn (`spawn_call`'s, `:proc_lib`'s, a `Task`'s),
  a `GenServer`, `:gen_server`, `:gen_statem` or `Supervisor` start with
  a literal callback module (`start_monitor` too), an `Agent`, a
  supervisor's `start_child`. The process registry is a heap field
  everyone shares: `register/2`, `:global.register_name/2`,
  `Registry.register/3` and a start with a literal `name:` store a pid
  under a name, and a send to that name, or a `whereis`, `whereis_name`
  or `Registry.lookup` of it, loads it back. The three registries are
  three namespaces (`name_of/1`).

  A pid is rarely held bare. A server keeps it in its state map, a client
  sends it in `{:subscribe, pid}`, a start returns it in `{:ok, pid}`. So
  the terms that hold pids are objects too, named by the instruction that
  built them (`put_map_*`, `put_tuple2`, `put_list`, `update_record`, or
  a call whose result has a known shape), with a field per map key, tuple
  position or list element. A read of `state.conn` is a load of the
  `:conn` field rather than everything the state holds, so two pids in one
  map stay two pids. A map update keeps the fields it does not set from
  the map it updates; a list's elements share one field, the collection
  abstraction.

  This extractor summarises, for every function, where the values it
  passes on came from, and `clientlib/processes.dl` chains the summaries
  across functions.

  ## Sources

  A value is a set of sources `{src_kind, src}`:

  - `proc` — the process started at a site in this function (its id);
  - `param` — a parameter position;
  - `result` — what the project call at a site returned (the site;
    `pid_result` names the callee);
  - `name` — a pid registered under a literal name: `:n` (or `Mod`),
    `{:global, :n}`, `{:via, Registry, {Reg, key}}`;
  - `self` — `self()`, which is whichever process runs the function;
  - `obj` — a term this function built (its id, see `pid_object`);
  - `load` — a field read from a term this function did not build (the
    load's id, see `pid_load`).

  ## Emitted facts

  - `process_start(id, func, proc, kind, runs)` — the start at `id` starts
    `proc` (`"<kind> <id>"`): `spawn` (`runs` is the function it runs, or
    `dynamic`), `server` (the callback module), `agent`.
  - `pid_arg(id, caller, callee, arg_pos, via, src_kind, src)` — at the
    call `id`, `callee`'s parameter `arg_pos` may hold the source. `via`
    is `call` for a call into project code, `init` for a server start's
    init argument (`Mod:init/1`), `spawn` for a spawned function's
    arguments, `child` for a child spec's argument (`Mod:start_link/1`)
    and `closure` for a closure's captured variables (its trailing
    parameters).
  - `pid_return(func, src_kind, src)` — `func` may return the source.
  - `pid_result(id, func, callee)` — the project call at `id` is to
    `callee`; its result is a `result` source somewhere.
  - `pid_call(id, func, api_kind, src_kind, src)` — the GenServer-style
    call or cast (`call`/`cast`, the `sync_call`/`async_cast` table) or
    send (`info`: to a server it lands in `handle_info/2`) at `id` targets
    the source.
  - `pid_message(id, func, api_kind, src_kind, src)` — the message of that
    call, cast or send is the source.
  - `pid_register(id, func, name, src_kind, src)` — the call at `id`
    registers the source under `name`; a start with a literal name
    registers the process it starts.
  - `pid_send(id, func, message, src_kind, src)` — the send at `id` goes to
    the source; `message` is the literal atom sent, `{:tag, …}` for a
    tuple with a literal atom first, or `dynamic`.
  - `pid_signal(id, func, signal, src_kind, src)` — the exit signal
    (`exit`: `Process.exit/2`, `:erlang.exit/2`), monitor (`monitor`),
    link (`link`) or unlink (`unlink`) at `id` goes to the source.
  - `pid_object(func, obj, shape, tag, arity)` — `func` builds the term
    `obj`: a `map`, `tuple` or `list`, with a tuple's literal atom tag and
    arity (else `""` and 0). Only a term that holds a source is an object.
  - `pid_field(func, obj, sel, src_kind, src)` — `obj`'s field `sel` holds
    the source: a map key (inspected), `{i}` for tuple position i
    (0-based), `[]` for a list's elements, `*` for a map key not known.
  - `pid_base(func, obj, src_kind, src)` — the term `obj` updates: the
    fields `obj` does not set are the base's (a list's tail is its base).
  - `pid_sets(obj, sel)` — a field an update sets, shadowing the base's.
  - `pid_load(func, load, sel, src_kind, src)` — the load `load` reads the
    field `sel` of the source.

  ## Reading the bytecode

  Per function, a sparse fixpoint over `Argus.Dataflow`'s reaching
  definitions: an instruction is evaluated again only when a definition
  it reads, or a term it read a field of, changes. A call into the
  runtime, `apply`, a BIF outside the structural few, and anything else
  not modelled yield nothing: what cannot be followed is lost rather than
  invented, so every rule on top of these facts stays quiet where it
  cannot be sure.

  Positions are symbols, not numbers, so the Datalog joins them to each
  other without the partial `to_number` functor.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Runtime
  alias Argus.Extractors.ApiCalls
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [add_fact: 3, register: 1]

  # A fixpoint over a finite lattice converges; the bound only guards a bug.
  @max_evaluations 64

  # Starts that return `{:ok, pid}`: the register holding the callback
  # module, and where the name is (`{:opts, reg}`: a `name:` option;
  # `{:tuple, reg}`: `{:local, n}`, `{:global, n}` or `{:via, m, k}`).
  @server_starts %{
    {GenServer, :start, 2} => {0, nil},
    {GenServer, :start, 3} => {0, {:opts, 2}},
    {GenServer, :start_link, 2} => {0, nil},
    {GenServer, :start_link, 3} => {0, {:opts, 2}},
    {:gen_server, :start, 3} => {0, nil},
    {:gen_server, :start, 4} => {1, {:tuple, 0}},
    {:gen_server, :start_link, 3} => {0, nil},
    {:gen_server, :start_link, 4} => {1, {:tuple, 0}},
    {:gen_statem, :start, 3} => {0, nil},
    {:gen_statem, :start, 4} => {1, {:tuple, 0}},
    {:gen_statem, :start_link, 3} => {0, nil},
    {:gen_statem, :start_link, 4} => {1, {:tuple, 0}},
    {GenStateMachine, :start, 2} => {0, nil},
    {GenStateMachine, :start, 3} => {0, {:opts, 2}},
    {GenStateMachine, :start_link, 2} => {0, nil},
    {GenStateMachine, :start_link, 3} => {0, {:opts, 2}},
    {Supervisor, :start_link, 3} => {0, {:opts, 2}},
    {:supervisor, :start_link, 2} => {0, nil},
    {:supervisor, :start_link, 3} => {1, {:tuple, 0}}
  }

  # Starts that return `{:ok, {pid, monitor_ref}}`.
  @monitor_starts %{
    {:gen_server, :start_monitor, 3} => {0, nil},
    {:gen_server, :start_monitor, 4} => {1, {:tuple, 0}},
    {:gen_statem, :start_monitor, 3} => {0, nil},
    {:gen_statem, :start_monitor, 4} => {1, {:tuple, 0}}
  }

  # A start through a supervisor returns the child's pid in `{:ok, pid}`;
  # the child spec in x1 names the module (`Mod`, `{Mod, arg}`,
  # `%{start: {Mod, ...}}`).
  @child_starts [{DynamicSupervisor, :start_child, 2}, {Supervisor, :start_child, 2}]

  # Spawns `spawn_call` does not cover (it resolves `:erlang.spawn*`): what
  # they return around the pid, and what runs — the closure in a register,
  # or a module, function and argument list from a register on.
  @other_spawns %{
    {:proc_lib, :spawn, 1} => {:pid, {:fun, 0}},
    {:proc_lib, :spawn_link, 1} => {:pid, {:fun, 0}},
    {:proc_lib, :spawn, 3} => {:pid, {:mfa, 0}},
    {:proc_lib, :spawn_link, 3} => {:pid, {:mfa, 0}},
    {:proc_lib, :spawn_opt, 4} => {:pid, {:mfa, 0}},
    {:erlang, :spawn_opt, 2} => {:pid, {:fun, 0}},
    {:erlang, :spawn_opt, 4} => {:pid, {:mfa, 0}},
    {Task, :start, 1} => {:ok, {:fun, 0}},
    {Task, :start_link, 1} => {:ok, {:fun, 0}},
    {Task, :start, 3} => {:ok, {:mfa, 0}},
    {Task, :start_link, 3} => {:ok, {:mfa, 0}},
    {Task, :async, 1} => {:task, {:fun, 0}},
    {Task, :async, 3} => {:task, {:mfa, 0}},
    {Task.Supervisor, :async, 2} => {:task, {:fun, 1}},
    {Task.Supervisor, :async, 3} => {:task, {:fun, 1}},
    {Task.Supervisor, :async, 4} => {:task, {:mfa, 1}},
    {Task.Supervisor, :async_nolink, 2} => {:task, {:fun, 1}},
    {Task.Supervisor, :async_nolink, 3} => {:task, {:fun, 1}},
    {Task.Supervisor, :async_nolink, 4} => {:task, {:mfa, 1}},
    {Task.Supervisor, :start_child, 2} => {:ok, {:fun, 1}},
    {Task.Supervisor, :start_child, 3} => {:ok, {:fun, 1}},
    {Task.Supervisor, :start_child, 4} => {:ok, {:mfa, 1}}
  }

  # An Agent is a server of Agent.Server's callbacks, whose state the
  # closures it is handed run on: what runs, and where the name is.
  @agent_starts %{
    {Agent, :start, 1} => {{:fun, 0}, nil},
    {Agent, :start, 2} => {{:fun, 0}, {:opts, 1}},
    {Agent, :start_link, 1} => {{:fun, 0}, nil},
    {Agent, :start_link, 2} => {{:fun, 0}, {:opts, 1}},
    {Agent, :start, 3} => {{:mfa, 0}, nil},
    {Agent, :start, 4} => {{:mfa, 0}, {:opts, 3}},
    {Agent, :start_link, 3} => {{:mfa, 0}, nil},
    {Agent, :start_link, 4} => {{:mfa, 0}, {:opts, 3}}
  }

  # Lookups of a literal name, by the registry the name lives in.
  @lookups %{
    {Process, :whereis, 1} => :local,
    {:erlang, :whereis, 1} => :local,
    {GenServer, :whereis, 1} => :any,
    {:global, :whereis_name, 1} => :global,
    {Registry, :whereis_name, 1} => :registry
  }

  # Library calls that read a field of a term: {term position, key
  # position}. The wrapped ones return `{:ok, value}`; the compiler's
  # slow path for `map.key` is one of them.
  @field_reads %{
    {Map, :get, 2} => {0, 1},
    {Map, :get, 3} => {0, 1},
    {Map, :fetch!, 2} => {0, 1},
    {:maps, :get, 2} => {1, 0},
    {:maps, :get, 3} => {1, 0},
    {Access, :get, 2} => {0, 1},
    {Access, :get, 3} => {0, 1}
  }

  @wrapped_field_reads %{
    {Map, :fetch, 2} => {0, 1},
    {:maps, :find, 2} => {1, 0},
    {:elixir_erl_pass, :no_parens_remote, 2} => {0, 1}
  }

  # Library calls that set a field: {term, key, value} positions.
  @field_writes %{
    {Map, :put, 3} => {0, 1, 2},
    {:maps, :put, 3} => {2, 0, 1}
  }

  @tail_ops [:call_only, :call_last, :call_ext_only, :call_ext_last]

  @impl true
  def relations,
    do: [
      :process_start,
      :pid_arg,
      :pid_return,
      :pid_result,
      :pid_call,
      :pid_message,
      :pid_register,
      :pid_send,
      :pid_signal,
      :pid_object,
      :pid_field,
      :pid_base,
      :pid_sets,
      :pid_load
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    case Helpers.reaching(module_data) do
      nil ->
        %{}

      reaching ->
        reads = reads_by_function(reaching)
        sites = sites_by_function(module_data)
        spawns = spawns_by_function(module_data)

        module_data.functions
        |> Enum.reduce(%{}, fn {:function, name, arity, _entry, instrs}, acc ->
          func_id = Normalize.func_id(module_data.module, name, arity)

          if generated?(func_id) do
            acc
          else
            fun = %{
              func_id: func_id,
              code: List.to_tuple(instrs),
              instrs: instrs,
              reads: Map.get(reads, func_id, %{}),
              sites: Map.get(sites, func_id, %{}),
              spawns: Map.get(spawns, func_id, %{})
            }

            function_facts(acc, fun)
          end
        end)
        |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    end
  end

  # ── The module, indexed per function ────────────────────────────────

  # %{func_id => %{idx => %{reg => [{:param, k} | {:def, idx}]}}}
  defp reads_by_function(reaching) do
    Enum.reduce(reaching, %{}, fn {source, reg, use}, acc ->
      func = InstrId.func_id(use.module, use.func, use.arity)

      from =
        case source do
          {:param, k} -> {:param, k}
          %InstrId{idx: d} -> {:def, d}
        end

      Map.update(acc, func, %{use.idx => %{reg => [from]}}, fn by_idx ->
        Map.update(by_idx, use.idx, %{reg => [from]}, fn regs ->
          Map.update(regs, reg, [from], &[from | &1])
        end)
      end)
    end)
  end

  defp sites_by_function(module_data) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(%{}, fn %{func_id: func, idx: idx} = site, acc ->
      Map.update(acc, func, %{idx => site}, &Map.put(&1, idx, site))
    end)
  end

  # The spawns Emit resolved: %{func_id => %{idx => {runs, arity}}}.
  defp spawns_by_function(module_data) do
    case Helpers.typed(module_data) do
      nil ->
        %{}

      typed ->
        for %{mod: mod, func: fun, arity: arity, id: id} <- Map.get(typed, :spawn_call, []),
            mod != "dynamic",
            reduce: %{} do
          acc ->
            func = InstrId.func_id(id.module, id.func, id.arity)
            spawn = {"#{mod}:#{fun}/#{arity}", arity}
            Map.update(acc, func, %{id.idx => spawn}, &Map.put(&1, id.idx, spawn))
        end
    end
  end

  # ── Allocation sites ─────────────────────────────────────────────────

  # %{idx => start}: every start in the function. `shape` is what the
  # call returns around the pid.
  defp starts(fun) do
    Enum.reduce(fun.sites, %{}, fn {idx, %{mfa: mfa, instrs: instrs}}, acc ->
      case start(fun, idx, mfa, instrs) do
        nil -> acc
        start -> Map.put(acc, idx, Map.put(start, :proc, "#{start.kind} #{site(fun, idx)}"))
      end
    end)
  end

  defp start(fun, idx, mfa, instrs) do
    cond do
      Map.has_key?(fun.spawns, idx) ->
        {runs, arity} = Map.fetch!(fun.spawns, idx)
        {_m, name, spawn_arity} = mfa
        shape = if name == :spawn_monitor, do: :pid_ref, else: :pid
        # The argument list follows the module and function, after the
        # node in the four-argument form.
        args = if spawn_arity == 4, do: {:x, 3}, else: {:x, 2}
        %{kind: "spawn", runs: runs, shape: shape, arity: arity, args: args}

      Map.has_key?(@server_starts, mfa) ->
        server_start(instrs, idx, Map.fetch!(@server_starts, mfa), :ok)

      Map.has_key?(@monitor_starts, mfa) ->
        server_start(instrs, idx, Map.fetch!(@monitor_starts, mfa), :monitor_ok)

      mfa in @child_starts ->
        with {:ok, spec} <- Helpers.resolve_register(instrs, idx, {:x, 1}),
             mod when mod != nil <- child_module(spec),
             false <- Runtime.module?(mod) do
          %{kind: "server", runs: inspect(mod), shape: :ok, child: true}
        else
          _ -> nil
        end

      Map.has_key?(@other_spawns, mfa) ->
        {shape, what} = Map.fetch!(@other_spawns, mfa)
        spawned(instrs, idx, what) |> Map.merge(%{kind: "spawn", shape: shape})

      Map.has_key?(@agent_starts, mfa) ->
        {what, name} = Map.fetch!(@agent_starts, mfa)

        spawned(instrs, idx, what)
        |> Map.merge(%{kind: "agent", shape: :ok, name: name_option(instrs, idx, name)})
        |> Map.delete(:args)

      true ->
        nil
    end
  end

  defp server_start(instrs, idx, {pos, name}, shape) do
    case Helpers.resolve_register(instrs, idx, {:x, pos}) do
      {:ok, mod} when is_atom(mod) and mod not in [nil, :dynamic] ->
        %{
          kind: "server",
          runs: inspect(mod),
          shape: shape,
          init_arg: {:x, pos + 1},
          name: name_option(instrs, idx, name)
        }

      _ ->
        nil
    end
  end

  # What a spawn runs: the closure in a register, resolved once the
  # function's values are known; or `M.F/length(args)` when all three are
  # literal, with the argument list's register for its elements.
  defp spawned(_instrs, _idx, {:fun, n}), do: %{runs: {:closure, {:x, n}}}

  defp spawned(instrs, idx, {:mfa, n}) do
    runs =
      with {:ok, mod} when is_atom(mod) and mod != :dynamic <-
             Helpers.resolve_register(instrs, idx, {:x, n}),
           {:ok, fun} when is_atom(fun) and fun != :dynamic <-
             Helpers.resolve_register(instrs, idx, {:x, n + 1}),
           {:ok, args} when is_list(args) <- Helpers.resolve_register(instrs, idx, {:x, n + 2}),
           true <- proper_list?(args) do
        Normalize.func_id(mod, fun, length(args))
      else
        _ -> "dynamic"
      end

    %{runs: runs, args: {:x, n + 2}}
  end

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  # A literal process name: `name:` in an options list, or the name tuple
  # an Erlang start takes first.
  defp name_option(_instrs, _idx, nil), do: nil

  defp name_option(instrs, idx, {:opts, n}) do
    case Helpers.resolve_register(instrs, idx, {:x, n}) do
      {:ok, opts} when is_list(opts) -> opts |> keyword_name() |> name_of()
      _ -> nil
    end
  end

  defp name_option(instrs, idx, {:tuple, n}) do
    case Helpers.resolve_register(instrs, idx, {:x, n}) do
      {:ok, {:local, name}} -> name_of(name)
      {:ok, {kind, _} = name} when kind in [:global, :via] -> name_of(name)
      {:ok, {:via, _, _} = name} -> name_of(name)
      _ -> nil
    end
  end

  defp keyword_name(opts) do
    Enum.find_value(opts, fn
      {:name, name} -> name
      _ -> nil
    end)
  end

  @doc """
  A process name as the registries spell it, the one spelling every
  relation uses: an atom for the local registry, `{:global, name}` and
  `{:via, module, key}` inspected whole, so the three namespaces never
  meet. `nil` for anything with an unknown part.

      iex> Argus.Extractors.PidFlow.name_of(:cache)
      ":cache"

      iex> Argus.Extractors.PidFlow.name_of({:global, :cache})
      "{:global, :cache}"

      iex> Argus.Extractors.PidFlow.name_of({:via, Registry, {MyReg, :dynamic}})
      nil
  """
  @spec name_of(term()) :: String.t() | nil
  def name_of(atom) when is_atom(atom) and atom not in [nil, true, false, :dynamic],
    do: inspect(atom)

  def name_of({:global, name} = global) do
    if literal?(name), do: inspect(global), else: nil
  end

  def name_of({:via, mod, key} = via) when is_atom(mod) and mod != :dynamic do
    if literal?(key), do: inspect(via), else: nil
  end

  def name_of(_other), do: nil

  defp literal?(:dynamic), do: false
  defp literal?(term) when is_atom(term) or is_number(term) or is_binary(term), do: true

  defp literal?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.all?(&literal?/1)

  defp literal?(term) when is_list(term), do: proper_list?(term) and Enum.all?(term, &literal?/1)
  defp literal?(_term), do: false

  defp child_module({mod, _arg}), do: child_module(mod)
  defp child_module(%{start: {mod, _fun, _args}}), do: child_module(mod)
  defp child_module(mod) when is_atom(mod) and mod not in [nil, :dynamic], do: mod
  defp child_module(_spec), do: nil

  # ── One function ────────────────────────────────────────────────────

  defp function_facts(facts, fun) do
    fun = Map.put(fun, :starts, starts(fun))
    users = users(fun.reads)
    idxs = Enum.to_list(0..(tuple_size(fun.code) - 1)//1)
    state = %{outs: %{}, objs: %{}, readers: %{}, count: %{}}
    state = run(:queue.from_list(idxs), MapSet.new(idxs), fun, users, state)
    emit(facts, fun, state)
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

  defp run(queue, pending, fun, users, state) do
    case :queue.out(queue) do
      {:empty, _queue} ->
        state

      {{:value, idx}, queue} ->
        pending = MapSet.delete(pending, idx)
        count = Map.get(state.count, idx, 0)

        if count >= @max_evaluations do
          run(queue, pending, fun, users, state)
        else
          state = %{state | count: Map.put(state.count, idx, count + 1)}
          result = evaluate(idx, fun, state)
          {targets, state} = commit(idx, result, users, state)
          {queue, pending} = enqueue(targets, queue, pending)
          run(queue, pending, fun, users, state)
        end
    end
  end

  defp enqueue(targets, queue, pending) do
    Enum.reduce(targets, {queue, pending}, fn target, {q, p} ->
      if MapSet.member?(p, target),
        do: {q, p},
        else: {:queue.in(target, q), MapSet.put(p, target)}
    end)
  end

  # Records what the evaluation wrote; returns the instructions to
  # evaluate again: the readers of a changed register, and the loads
  # through a term whose fields changed.
  defp commit(idx, result, users, state) do
    {changed_regs?, outs} =
      Enum.reduce(result.writes, {false, state.outs}, fn {reg, value}, {changed?, outs} ->
        if Map.get(outs, {idx, reg}) == value,
          do: {changed?, outs},
          else: {true, Map.put(outs, {idx, reg}, value)}
      end)

    readers =
      Enum.reduce(result.read_objs, state.readers, fn obj, acc ->
        Map.update(acc, obj, MapSet.new([idx]), &MapSet.put(&1, idx))
      end)

    {changed_objs, objs} =
      Enum.reduce(result.objs, {[], state.objs}, fn {key, obj}, {changed, objs} ->
        if Map.get(objs, key) == obj,
          do: {changed, objs},
          else: {[key | changed], Map.put(objs, key, obj)}
      end)

    targets =
      if(changed_regs?, do: Map.get(users, idx, []), else: []) ++
        Enum.flat_map(changed_objs, &MapSet.to_list(Map.get(readers, &1, MapSet.new())))

    {targets, %{state | outs: outs, objs: objs, readers: readers}}
  end

  # ── What an instruction writes ───────────────────────────────────────

  defp new_result, do: %{writes: [], objs: [], read_objs: [], loads: []}

  defp evaluate(idx, fun, state) do
    ctx = %{idx: idx, fun: fun, state: state}
    instr = elem(fun.code, idx)

    case Map.fetch(fun.sites, idx) do
      {:ok, site} -> call(ctx, site, new_result())
      :error -> instruction(ctx, instr, new_result())
    end
  end

  defp instruction(ctx, {:move, src, dst}, r), do: write(r, dst, val(ctx, src))

  defp instruction(ctx, {:swap, a, b}, r),
    do: r |> write(a, val(ctx, b)) |> write(b, val(ctx, a))

  # A trim renumbers the stack frame: each kept slot takes the value of
  # the slot it replaces.
  defp instruction(ctx, {:trim, _n, _remaining} = trim, r) do
    Enum.reduce(Instr.defs(trim), r, fn dst, acc ->
      write(acc, dst, val(ctx, Instr.copy_source(trim, dst)))
    end)
  end

  defp instruction(ctx, {:get_list, src, head, tail}, r) do
    {value, r} = load(ctx, val(ctx, src), "[]", load_id(ctx, "[]"), r)
    r |> write(head, value) |> write(tail, val(ctx, src))
  end

  defp instruction(ctx, {:get_hd, src, head}, r) do
    {value, r} = load(ctx, val(ctx, src), "[]", load_id(ctx, "[]"), r)
    write(r, head, value)
  end

  defp instruction(ctx, {:get_tl, src, tail}, r), do: write(r, tail, val(ctx, src))

  defp instruction(ctx, {:put_list, head, tail, dst}, r) do
    obj = %{
      shape: "list",
      fields: %{"[]" => val(ctx, head)},
      base: val(ctx, tail),
      keys: MapSet.new(),
      tag: "",
      arity: 0,
      nil_tail: tail == nil
    }

    r |> object(ctx.idx, obj) |> write(dst, obj_token(ctx.idx))
  end

  defp instruction(ctx, {:put_tuple2, dst, {:list, elements}}, r) do
    fields =
      elements
      |> Enum.with_index()
      |> Map.new(fn {operand, i} -> {"{#{i}}", val(ctx, operand)} end)

    tag =
      case elements do
        [{:atom, atom} | _] -> inspect(atom)
        _ -> ""
      end

    obj = %{
      shape: "tuple",
      fields: fields,
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: tag,
      arity: length(elements)
    }

    r |> object(ctx.idx, obj) |> write(dst, obj_token(ctx.idx))
  end

  defp instruction(ctx, {:get_tuple_element, src, i, dst}, r) do
    sel = "{#{i}}"
    {value, r} = load(ctx, val(ctx, src), sel, load_id(ctx, sel), r)
    write(r, dst, value)
  end

  defp instruction(ctx, {op, _fail, src, dst, _live, {:list, pairs}}, r)
       when op in [:put_map_assoc, :put_map_exact] do
    {fields, keys} =
      pairs
      |> Enum.chunk_every(2)
      |> Enum.reduce({%{}, MapSet.new()}, fn [key, value], {fields, keys} ->
        sel = selector(key)
        fields = Map.update(fields, sel, val(ctx, value), &MapSet.union(&1, val(ctx, value)))
        keys = if sel == "*", do: keys, else: MapSet.put(keys, sel)
        {fields, keys}
      end)

    obj = %{shape: "map", fields: fields, base: val(ctx, src), keys: keys, tag: "", arity: 0}
    r |> object(ctx.idx, obj) |> write(dst, obj_token(ctx.idx))
  end

  defp instruction(ctx, {:get_map_elements, _fail, src, {:list, pairs}}, r) do
    base = val(ctx, src)

    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(r, fn [key, dst], acc ->
      sel = selector(key)
      {value, acc} = load(ctx, base, sel, load_id(ctx, sel), acc)
      write(acc, dst, value)
    end)
  end

  # Positions are 1-based in the instruction.
  defp instruction(ctx, {:update_record, _hint, size, src, dst, {:list, updates}}, r) do
    {fields, keys} =
      updates
      |> Enum.chunk_every(2)
      |> Enum.reduce({%{}, MapSet.new()}, fn
        [{:integer, pos}, value], {fields, keys} ->
          sel = "{#{pos - 1}}"
          {Map.put(fields, sel, val(ctx, value)), MapSet.put(keys, sel)}

        _other, acc ->
          acc
      end)

    obj = %{shape: "tuple", fields: fields, base: val(ctx, src), keys: keys, tag: "", arity: size}
    r |> object(ctx.idx, obj) |> write(dst, obj_token(ctx.idx))
  end

  defp instruction(ctx, {:bif, name, _fail, args, dst}, r), do: bif(ctx, name, args, dst, r)

  defp instruction(ctx, {:gc_bif, name, _fail, _live, args, dst}, r),
    do: bif(ctx, name, args, dst, r)

  # A closure is not a pid, but what a spawn of it runs.
  defp instruction(_ctx, {:make_fun3, {mod, name, arity}, _index, _uniq, dst, _env}, r),
    do: write(r, dst, MapSet.new([{:fun, Normalize.func_id(mod, name, arity)}]))

  defp instruction(_ctx, _instr, r), do: r

  defp bif(_ctx, :self, [], dst, r), do: write(r, dst, MapSet.new([:self]))

  defp bif(ctx, :element, [{:integer, pos}, tuple], dst, r) do
    sel = "{#{pos - 1}}"
    {value, r} = load(ctx, val(ctx, tuple), sel, load_id(ctx, sel), r)
    write(r, dst, value)
  end

  defp bif(ctx, :hd, [list], dst, r) do
    {value, r} = load(ctx, val(ctx, list), "[]", load_id(ctx, "[]"), r)
    write(r, dst, value)
  end

  defp bif(ctx, :tl, [list], dst, r), do: write(r, dst, val(ctx, list))

  defp bif(ctx, :map_get, [key, map], dst, r) do
    sel = selector(key)
    {value, r} = load(ctx, val(ctx, map), sel, load_id(ctx, sel), r)
    write(r, dst, value)
  end

  defp bif(_ctx, _name, _args, _dst, r), do: r

  # ── Calls ────────────────────────────────────────────────────────────

  defp call(ctx, %{mfa: mfa, instrs: instrs} = site, r) do
    idx = ctx.idx

    cond do
      Map.has_key?(ctx.fun.starts, idx) ->
        start_result(ctx, Map.fetch!(ctx.fun.starts, idx), r)

      Map.has_key?(@lookups, mfa) ->
        write(r, {:x, 0}, lookup(ctx, instrs, idx, Map.fetch!(@lookups, mfa)))

      mfa == {Registry, :lookup, 2} ->
        registry_lookup(ctx, instrs, r)

      Map.has_key?(@field_reads, mfa) ->
        {term, key} = Map.fetch!(@field_reads, mfa)
        {value, r} = library_load(ctx, term, key, r)
        write(r, {:x, 0}, value)

      Map.has_key?(@wrapped_field_reads, mfa) ->
        {term, key} = Map.fetch!(@wrapped_field_reads, mfa)
        {value, r} = library_load(ctx, term, key, r)
        ok_tuple(ctx, value, r)

      Map.has_key?(@field_writes, mfa) ->
        {term, key, value} = Map.fetch!(@field_writes, mfa)
        sel = literal_selector(instrs, idx, key)

        obj = %{
          shape: "map",
          fields: %{sel => val(ctx, {:x, value})},
          base: val(ctx, {:x, term}),
          keys: if(sel == "*", do: MapSet.new(), else: MapSet.new([sel])),
          tag: "",
          arity: 0
        }

        r |> object(idx, obj) |> write({:x, 0}, obj_token(idx))

      project?(site) ->
        write(r, {:x, 0}, MapSet.new([{:result, idx}]))

      true ->
        r
    end
  end

  # What a lookup of the name in x0 returns: the pid registered under it.
  # GenServer.whereis/1 takes any server reference, a pid included.
  defp lookup(ctx, instrs, idx, registry) do
    case Helpers.resolve_register(instrs, idx, {:x, 0}) do
      {:ok, name} ->
        case lookup_name(registry, name) do
          nil -> MapSet.new()
          spelled -> MapSet.new([{:name, spelled}])
        end

      _ when registry == :any ->
        val(ctx, {:x, 0})

      _ ->
        MapSet.new()
    end
  end

  defp lookup_name(:local, name) when is_atom(name), do: name_of(name)
  defp lookup_name(:global, name), do: name_of({:global, name})
  defp lookup_name(:registry, {registry, key}), do: name_of({:via, Registry, {registry, key}})
  defp lookup_name(:any, name), do: name_of(name)
  defp lookup_name(_registry, _name), do: nil

  # `Registry.lookup(reg, key)` returns `[{pid, value}]`: a list whose
  # elements are tuples holding the pid registered under the key.
  defp registry_lookup(ctx, instrs, r) do
    idx = ctx.idx

    with {:ok, registry} <- Helpers.resolve_register(instrs, idx, {:x, 0}),
         {:ok, key} <- Helpers.resolve_register(instrs, idx, {:x, 1}),
         name when name != nil <- name_of({:via, Registry, {registry, key}}) do
      entry = %{
        shape: "tuple",
        fields: %{"{0}" => MapSet.new([{:name, name}])},
        base: MapSet.new(),
        keys: MapSet.new(),
        tag: "",
        arity: 2
      }

      list = %{
        shape: "list",
        fields: %{"[]" => obj_token({idx, 1})},
        base: MapSet.new(),
        keys: MapSet.new(),
        tag: "",
        arity: 0,
        nil_tail: true
      }

      r |> object({idx, 1}, entry) |> object(idx, list) |> write({:x, 0}, obj_token(idx))
    else
      _ -> r
    end
  end

  defp library_load(ctx, term, key, r) do
    sel = literal_selector(ctx.fun.instrs, ctx.idx, key)
    load(ctx, val(ctx, {:x, term}), sel, load_id(ctx, sel), r)
  end

  defp start_result(_ctx, %{proc: proc, shape: :pid}, r),
    do: write(r, {:x, 0}, MapSet.new([{:proc, proc}]))

  # `spawn_monitor/1,3` returns `{pid, ref}`.
  defp start_result(ctx, %{proc: proc, shape: :pid_ref}, r) do
    obj = %{
      shape: "tuple",
      fields: %{"{0}" => MapSet.new([{:proc, proc}])},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: "",
      arity: 2
    }

    r |> object(ctx.idx, obj) |> write({:x, 0}, obj_token(ctx.idx))
  end

  defp start_result(ctx, %{proc: proc, shape: :ok}, r),
    do: ok_tuple(ctx, MapSet.new([{:proc, proc}]), r)

  # `start_monitor` returns `{:ok, {pid, ref}}`.
  defp start_result(ctx, %{proc: proc, shape: :monitor_ok}, r) do
    pair = %{
      shape: "tuple",
      fields: %{"{0}" => MapSet.new([{:proc, proc}])},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: "",
      arity: 2
    }

    r = object(r, {ctx.idx, 1}, pair)
    ok_tuple(ctx, obj_token({ctx.idx, 1}), r)
  end

  # `Task.async` returns a `%Task{}`: its `:pid`, and its `:owner`, the
  # caller.
  defp start_result(ctx, %{proc: proc, shape: :task}, r) do
    obj = %{
      shape: "map",
      fields: %{":pid" => MapSet.new([{:proc, proc}]), ":owner" => MapSet.new([:self])},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: "",
      arity: 0
    }

    r |> object(ctx.idx, obj) |> write({:x, 0}, obj_token(ctx.idx))
  end

  defp ok_tuple(ctx, value, r) do
    obj = %{
      shape: "tuple",
      fields: %{"{1}" => value},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: ":ok",
      arity: 2
    }

    r |> object(ctx.idx, obj) |> write({:x, 0}, obj_token(ctx.idx))
  end

  # ── Values ───────────────────────────────────────────────────────────

  # What `operand` may hold when `ctx.idx` reads it.
  defp val(ctx, operand) do
    case register(operand) do
      {kind, n} when kind in [:x, :y] ->
        reg = "#{kind}#{n}"

        ctx.fun.reads
        |> Map.get(ctx.idx, %{})
        |> Map.get(reg, [])
        |> Enum.reduce(MapSet.new(), fn
          {:param, k}, acc -> MapSet.put(acc, {:param, k})
          {:def, d}, acc -> MapSet.union(acc, Map.get(ctx.state.outs, {d, reg}, MapSet.new()))
        end)

      _literal ->
        MapSet.new()
    end
  end

  defp write(r, operand, value) do
    case register(operand) do
      {kind, n} when kind in [:x, :y] -> %{r | writes: [{"#{kind}#{n}", value} | r.writes]}
      _other -> r
    end
  end

  defp object(r, key, obj), do: %{r | objs: [{key, obj} | r.objs]}

  defp obj_token(key), do: MapSet.new([{:obj, key}])

  defp load_id(ctx, sel), do: site(ctx.fun, ctx.idx) <> " " <> sel

  # Reads field `sel` of every term in `value`. A term built here is read
  # directly (its field, a map's unknown-key field, and the base's field
  # when the term does not set it); a term from elsewhere becomes a load
  # the Datalog resolves; a pid has no fields.
  defp load(ctx, value, sel, id, r), do: load(ctx, value, sel, id, r, %{})

  defp load(ctx, value, sel, id, r, seen) do
    Enum.reduce(value, {MapSet.new(), r}, fn token, {acc, r} ->
      case token do
        {:obj, key} ->
          if Map.has_key?(seen, key) do
            {acc, r}
          else
            r = %{r | read_objs: [key | r.read_objs]}

            local_field(
              ctx,
              Map.get(ctx.state.objs, key),
              sel,
              id,
              r,
              Map.put(seen, key, true),
              acc
            )
          end

        {kind, _} when kind in [:param, :result, :load] ->
          {MapSet.put(acc, {:load, id}), %{r | loads: [{id, sel, token} | r.loads]}}

        _pid_or_fun ->
          {acc, r}
      end
    end)
  end

  defp local_field(_ctx, nil, _sel, _id, r, _seen, acc), do: {acc, r}

  defp local_field(ctx, obj, sel, id, r, seen, acc) do
    own =
      obj.fields
      |> Map.get(sel, MapSet.new())
      |> MapSet.union(
        if obj.shape == "map", do: Map.get(obj.fields, "*", MapSet.new()), else: MapSet.new()
      )

    acc = MapSet.union(acc, own)

    if MapSet.member?(obj.keys, sel) do
      {acc, r}
    else
      {inherited, r} = load(ctx, obj.base, sel, id, r, seen)
      {MapSet.union(acc, inherited), r}
    end
  end

  # A map key as a field name: the inspected literal, or `*`.
  defp selector({:atom, atom}), do: inspect(atom)
  defp selector({:integer, n}), do: inspect(n)
  defp selector({:float, f}), do: inspect(f)
  defp selector({:literal, term}), do: inspect(term)
  defp selector(nil), do: inspect([])
  defp selector(_register), do: "*"

  defp literal_selector(instrs, idx, pos) do
    case Helpers.resolve_register(instrs, idx, {:x, pos}) do
      {:ok, key} when is_atom(key) and key != :dynamic -> inspect(key)
      {:ok, key} when is_binary(key) or is_integer(key) -> inspect(key)
      _ -> "*"
    end
  end

  # ── Emission ─────────────────────────────────────────────────────────

  defp emit(facts, fun, state) do
    live = live_objects(state.objs)
    ctx = %{fun: fun, state: state, live: live}

    facts
    |> emit_starts(fun, state)
    |> emit_objects(ctx)
    |> emit_instructions(ctx)
  end

  defp emit_starts(facts, fun, state) do
    Enum.reduce(fun.starts, facts, fn {idx, start}, acc ->
      id = site(fun, idx)
      runs = runs(start, %{idx: idx, fun: fun, state: state})
      acc = add_fact(acc, :process_start, [id, fun.func_id, start.proc, start.kind, runs])

      # A start with a literal name registers the process under it.
      case Map.get(start, :name) do
        nil -> acc
        name -> add_fact(acc, :pid_register, [id, fun.func_id, name, "proc", start.proc])
      end
    end)
  end

  # A closure's function once the register holding it is known: exactly
  # one, or unknown.
  defp runs(%{runs: {:closure, reg}}, ictx) do
    case for({:fun, closure} <- val(ictx, reg), do: closure) do
      [closure] -> closure
      _ -> "dynamic"
    end
  end

  defp runs(%{runs: runs}, _ictx), do: runs

  # The terms that hold a source: a field or base with anything but a
  # term, or with a term that does. Fixpoint over the function's terms.
  defp live_objects(objs, live \\ %{}) do
    grown =
      Enum.reduce(objs, live, fn {key, obj}, acc ->
        if Map.has_key?(acc, key) or not holds_source?(obj, acc),
          do: acc,
          else: Map.put(acc, key, true)
      end)

    if map_size(grown) == map_size(live), do: live, else: live_objects(objs, grown)
  end

  defp holds_source?(obj, live) do
    obj.fields
    |> Map.values()
    |> Enum.concat([obj.base])
    |> Enum.any?(fn value -> Enum.any?(value, &source?(&1, live)) end)
  end

  defp source?({:obj, key}, live), do: Map.has_key?(live, key)
  defp source?({:fun, _closure}, _live), do: false
  defp source?(_token, _live), do: true

  defp emit_objects(facts, ctx) do
    func = ctx.fun.func_id

    Enum.reduce(Map.keys(ctx.live), facts, fn key, acc ->
      obj = Map.fetch!(ctx.state.objs, key)
      id = obj_id(ctx.fun, key)
      acc = add_fact(acc, :pid_object, [func, id, obj.shape, obj.tag, to_string(obj.arity)])

      acc =
        Enum.reduce(obj.fields, acc, fn {sel, value}, inner ->
          sources(inner, ctx, :pid_field, [func, id, sel], value)
        end)

      acc = sources(acc, ctx, :pid_base, [func, id], obj.base)

      if convert(ctx, obj.base) == [],
        do: acc,
        else: Enum.reduce(obj.keys, acc, &add_fact(&2, :pid_sets, [id, &1]))
    end)
  end

  defp emit_instructions(facts, ctx) do
    fun = ctx.fun

    Enum.reduce(0..(tuple_size(fun.code) - 1)//1, facts, fn idx, acc ->
      ictx = %{idx: idx, fun: fun, state: ctx.state}
      result = evaluate(idx, fun, ctx.state)
      at = Map.put(ctx, :idx, idx)

      acc =
        Enum.reduce(result.loads, acc, fn {id, sel, token}, inner ->
          sources(inner, ctx, :pid_load, [fun.func_id, id, sel], MapSet.new([token]))
        end)

      case Map.fetch(fun.sites, idx) do
        {:ok, site} -> emit_site(acc, at, ictx, site)
        :error -> emit_other(acc, at, ictx, elem(fun.code, idx))
      end
    end)
  end

  defp emit_other(facts, at, ictx, :return),
    do: sources(facts, at, :pid_return, [at.fun.func_id], val(ictx, {:x, 0}))

  defp emit_other(facts, at, ictx, :send), do: send_row(facts, at, ictx)

  defp emit_other(
         facts,
         at,
         ictx,
         {:make_fun3, {cmod, cname, carity}, _index, _uniq, _dst, {:list, env}}
       ) do
    closure = Normalize.func_id(cmod, cname, carity)
    first = carity - length(env)

    env
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {operand, slot}, acc ->
      sources(
        acc,
        at,
        :pid_arg,
        [site(at.fun, at.idx), at.fun.func_id, closure, to_string(first + slot), "closure"],
        val(ictx, operand)
      )
    end)
  end

  defp emit_other(facts, _at, _ictx, _instr), do: facts

  defp emit_site(facts, at, ictx, %{mfa: mfa} = site) do
    facts
    |> emit_args(at, ictx, site)
    |> emit_start_args(at, ictx, Map.get(at.fun.starts, at.idx))
    |> emit_process_call(at, ictx, mfa)
    |> emit_register(at, ictx, mfa)
    |> emit_send(at, ictx, mfa)
    |> emit_signal(at, ictx, mfa)
    |> emit_tail(at, ictx, site)
  end

  # Every argument of a call into project code.
  defp emit_args(facts, at, ictx, %{mfa: {_m, _f, arity} = mfa} = site) do
    if project?(site) do
      Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
        sources(
          acc,
          at,
          :pid_arg,
          [site(at.fun, at.idx), at.fun.func_id, callee(mfa), to_string(pos), "call"],
          val(ictx, {:x, pos})
        )
      end)
    else
      facts
    end
  end

  # A server's init/1 receives the start's init argument.
  defp emit_start_args(facts, at, ictx, %{kind: "server", runs: mod, init_arg: reg}) do
    sources(
      facts,
      at,
      :pid_arg,
      [site(at.fun, at.idx), at.fun.func_id, "#{mod}:init/1", "0", "init"],
      val(ictx, reg)
    )
  end

  # A child spec `{Mod, arg}` starts `Mod.start_link(arg)`.
  defp emit_start_args(facts, at, ictx, %{kind: "server", runs: mod, child: true}) do
    r = new_result()
    {arg, r} = load(ictx, val(ictx, {:x, 1}), "{1}", site(at.fun, at.idx) <> " {1}", r)
    facts = emit_loads(facts, at, r)

    sources(
      facts,
      at,
      :pid_arg,
      [site(at.fun, at.idx), at.fun.func_id, "#{mod}:start_link/1", "0", "child"],
      arg
    )
  end

  # A spawned function's parameters are the elements of the argument list.
  defp emit_start_args(facts, at, ictx, %{kind: "spawn", runs: runs, args: reg})
       when runs != "dynamic" do
    case list_elements(ictx, val(ictx, reg)) do
      {:ok, elements} ->
        elements
        |> Enum.with_index()
        |> Enum.reduce(facts, fn {value, pos}, acc ->
          sources(
            acc,
            at,
            :pid_arg,
            [site(at.fun, at.idx), at.fun.func_id, runs, to_string(pos), "spawn"],
            value
          )
        end)

      :unknown ->
        facts
    end
  end

  defp emit_start_args(facts, _at, _ictx, _start), do: facts

  # The positional elements of a list built here, when every cons cell
  # is: `[a, b]` is two cells ending in `[]`.
  defp list_elements(ictx, value) do
    case MapSet.to_list(value) do
      [] ->
        {:ok, []}

      [{:obj, key}] ->
        case Map.get(ictx.state.objs, key) do
          %{shape: "list", fields: %{"[]" => head}, base: tail, nil_tail: nil_tail?} ->
            cond do
              nil_tail? -> {:ok, [head]}
              MapSet.size(tail) == 0 -> :unknown
              true -> list_tail(ictx, head, tail)
            end

          _ ->
            :unknown
        end

      _ ->
        :unknown
    end
  end

  defp list_tail(ictx, head, tail) do
    case list_elements(ictx, tail) do
      {:ok, rest} -> {:ok, [head | rest]}
      :unknown -> :unknown
    end
  end

  # The target in x0 (a pid, or a literal name), and the message in x1.
  defp emit_process_call(facts, at, ictx, mfa) do
    case ApiCalls.process_call_kind(mfa) do
      nil -> facts
      kind -> call_rows(facts, at, ictx, to_string(kind))
    end
  end

  defp call_rows(facts, at, ictx, kind) do
    id = site(at.fun, at.idx)

    facts
    |> sources(at, :pid_call, [id, at.fun.func_id, kind], destination(at, ictx))
    |> sources(at, :pid_message, [id, at.fun.func_id, kind], val(ictx, {:x, 1}))
  end

  defp destination(at, ictx, reg \\ {:x, 0}) do
    value = val(ictx, reg)

    with {:ok, term} <- Helpers.resolve_register(at.fun.instrs, at.idx, reg),
         name when name != nil <- name_of(term) do
      MapSet.put(value, {:name, name})
    else
      _ -> value
    end
  end

  # An exit signal, a monitor or a link, with the register naming the
  # process it goes to.
  @signals %{
    {Process, :exit, 2} => {"exit", {:x, 0}},
    {:erlang, :exit, 2} => {"exit", {:x, 0}},
    {Process, :monitor, 1} => {"monitor", {:x, 0}},
    {Process, :monitor, 2} => {"monitor", {:x, 0}},
    {:erlang, :monitor, 2} => {"monitor", {:x, 1}},
    {:erlang, :monitor, 3} => {"monitor", {:x, 1}},
    {Process, :link, 1} => {"link", {:x, 0}},
    {:erlang, :link, 1} => {"link", {:x, 0}},
    {Process, :unlink, 1} => {"unlink", {:x, 0}},
    {:erlang, :unlink, 1} => {"unlink", {:x, 0}}
  }

  defp emit_signal(facts, at, ictx, mfa) do
    case Map.fetch(@signals, mfa) do
      {:ok, {signal, reg}} ->
        sources(
          facts,
          at,
          :pid_signal,
          [site(at.fun, at.idx), at.fun.func_id, signal],
          destination(at, ictx, reg)
        )

      :error ->
        facts
    end
  end

  defp emit_register(facts, at, ictx, {Process, :register, 2}),
    do:
      register_row(
        facts,
        at,
        Helpers.resolve_atom(at.fun.instrs, at.idx, {:x, 1}),
        val(ictx, {:x, 0})
      )

  defp emit_register(facts, at, ictx, {:erlang, :register, 2}),
    do:
      register_row(
        facts,
        at,
        Helpers.resolve_atom(at.fun.instrs, at.idx, {:x, 0}),
        val(ictx, {:x, 1})
      )

  defp emit_register(facts, at, ictx, {:global, :register_name, arity}) when arity in [2, 3] do
    name =
      case Helpers.resolve_register(at.fun.instrs, at.idx, {:x, 0}) do
        {:ok, name} -> name_of({:global, name}) || "dynamic"
        _ -> "dynamic"
      end

    register_row(facts, at, name, val(ictx, {:x, 1}))
  end

  # A process registers itself under a key of a Registry.
  defp emit_register(facts, at, _ictx, {Registry, :register, 3}) do
    instrs = at.fun.instrs

    name =
      with {:ok, registry} <- Helpers.resolve_register(instrs, at.idx, {:x, 0}),
           {:ok, key} <- Helpers.resolve_register(instrs, at.idx, {:x, 1}) do
        name_of({:via, Registry, {registry, key}}) || "dynamic"
      else
        _ -> "dynamic"
      end

    register_row(facts, at, name, MapSet.new([:self]))
  end

  defp emit_register(facts, _at, _ictx, _mfa), do: facts

  defp register_row(facts, _at, "dynamic", _value), do: facts

  defp register_row(facts, at, name, value),
    do: sources(facts, at, :pid_register, [site(at.fun, at.idx), at.fun.func_id, name], value)

  defp emit_send(facts, at, ictx, {mod, :send, arity})
       when (mod == :erlang and arity in [2, 3]) or (mod == Process and arity == 3),
       do: send_row(facts, at, ictx)

  defp emit_send(facts, _at, _ictx, _mfa), do: facts

  # A send is keyed on its site for the finding about what it sends, and is
  # also an "info" call: to a server, the message lands in handle_info/2.
  defp send_row(facts, at, ictx) do
    id = site(at.fun, at.idx)
    message = message(at.fun.instrs, at.idx)

    facts
    |> sources(at, :pid_send, [id, at.fun.func_id, message], destination(at, ictx))
    |> call_rows(at, ictx, "info")
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

  # A tail call returns whatever the call returns.
  defp emit_tail(facts, at, ictx, _site) do
    if elem(elem(at.fun.code, at.idx), 0) in @tail_ops do
      value = Map.get(ictx.state.outs, {at.idx, "x0"}, MapSet.new())
      sources(facts, at, :pid_return, [at.fun.func_id], value)
    else
      facts
    end
  end

  defp emit_loads(facts, at, r) do
    Enum.reduce(r.loads, facts, fn {id, sel, token}, inner ->
      sources(inner, at, :pid_load, [at.fun.func_id, id, sel], MapSet.new([token]))
    end)
  end

  # ── Sources as rows ──────────────────────────────────────────────────

  defp sources(facts, ctx, relation, prefix, value) do
    emit_rows(facts, relation, prefix, convert(ctx, value))
    |> emit_results(ctx, value)
  end

  defp emit_rows(facts, relation, prefix, converted) do
    Enum.reduce(converted, facts, fn {kind, src}, acc ->
      emit_row(acc, relation, prefix ++ [kind, src])
    end)
  end

  # A `result` source names its call site; `pid_result` says what it calls.
  defp emit_results(facts, ctx, value) do
    Enum.reduce(value, facts, fn
      {:result, idx}, acc ->
        %{mfa: mfa} = Map.fetch!(ctx.fun.sites, idx)
        add_fact(acc, :pid_result, [site(ctx.fun, idx), ctx.fun.func_id, callee(mfa)])

      _token, acc ->
        acc
    end)
  end

  defp convert(ctx, value) do
    value
    |> Enum.flat_map(fn
      {:proc, proc} ->
        [{"proc", proc}]

      {:param, k} ->
        [{"param", Integer.to_string(k)}]

      {:result, idx} ->
        [{"result", site(ctx.fun, idx)}]

      {:name, name} ->
        [{"name", name}]

      :self ->
        [{"self", "self"}]

      {:load, id} ->
        [{"load", id}]

      {:obj, key} ->
        if Map.has_key?(ctx.live, key), do: [{"obj", obj_id(ctx.fun, key)}], else: []

      {:fun, _closure} ->
        []
    end)
    |> Enum.sort()
  end

  # One literal add_fact per relation, so the relation list stays
  # checkable against the source.
  defp emit_row(facts, :pid_arg, row), do: add_fact(facts, :pid_arg, row)
  defp emit_row(facts, :pid_return, row), do: add_fact(facts, :pid_return, row)
  defp emit_row(facts, :pid_call, row), do: add_fact(facts, :pid_call, row)
  defp emit_row(facts, :pid_message, row), do: add_fact(facts, :pid_message, row)
  defp emit_row(facts, :pid_register, row), do: add_fact(facts, :pid_register, row)
  defp emit_row(facts, :pid_send, row), do: add_fact(facts, :pid_send, row)
  defp emit_row(facts, :pid_signal, row), do: add_fact(facts, :pid_signal, row)
  defp emit_row(facts, :pid_field, row), do: add_fact(facts, :pid_field, row)
  defp emit_row(facts, :pid_base, row), do: add_fact(facts, :pid_base, row)
  defp emit_row(facts, :pid_load, row), do: add_fact(facts, :pid_load, row)

  # ── Names ────────────────────────────────────────────────────────────

  defp site(fun, idx), do: InstrId.mint(fun.func_id, idx)

  # A term a call builds inside its result has a second name at the site.
  defp obj_id(fun, {idx, n}), do: site(fun, idx) <> "/" <> Integer.to_string(n)
  defp obj_id(fun, idx), do: site(fun, idx)

  # A local call, or a remote call into a module outside the runtime
  # (`Argus.Extractor.Runtime`): the only callees whose own summaries can
  # say what they do with a pid. Runtime calls are neither followed nor
  # recorded, which keeps the relations to the program's own code.
  defp project?(%{remote?: false}), do: true
  defp project?(%{mfa: {mod, _f, _a}}), do: not Runtime.module?(mod)

  defp generated?(func_id) do
    String.contains?(func_id, [":__info__/", ":module_info/", ":-inlined-"])
  end

  defp callee({mod, fun, arity}), do: Normalize.func_id(mod, fun, arity)
end
