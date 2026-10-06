defmodule Argus.Extractors.TermFlow do
  @moduledoc """
  Intraprocedural provenance summaries for values, containers and processes.

  Values include parameters, project-call results, replies, ETS tables and
  process-dictionary contents. Register reads join sources from reaching
  definitions; containers retain field identity
  through construction, updates and reads. `Argus.Extractors.TermFlow.Heap`
  models local containers, and `Argus.Extractor.ValueFlow` solves the coupled
  register/heap equations. Datalog connects these summaries across functions.

  Unknown operations lose provenance. An empty source set therefore means
  "no modeled source", not "safe" or "no possible value". Branch joins and
  allocation-site merging can also retain infeasible sources.

  See `docs/design/value-flow.md` for the model, supported operations,
  relation families and limits.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg.Function, as: Graph
  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Runtime
  alias Argus.Extractor.Terms
  alias Argus.Extractor.ValueFlow
  alias Argus.Extractors.ApiCalls
  alias Argus.Extractors.TermFlow.Heap
  alias Argus.Extractors.TermFlow.Library
  alias Argus.Instr
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers, only: [register: 1]
  import Argus.Extractor.Facts, only: [add_fact: 3]

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
    {GenStage, :start, 2} => {0, nil},
    {GenStage, :start, 3} => {0, {:opts, 2}},
    {GenStage, :start_link, 2} => {0, nil},
    {GenStage, :start_link, 3} => {0, {:opts, 2}},
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
    {Task.Supervisor, :start_child, 4} => {:ok, {:mfa, 1}},
    # A timer runs the MFA in a process of its own when it fires, and
    # answers `{:ok, tref}`: nothing the caller can reach the process by.
    {:timer, :apply_after, 4} => {:none, {:mfa, 1}},
    {:timer, :apply_interval, 4} => {:none, {:mfa, 1}},
    {:timer, :apply_repeatedly, 4} => {:none, {:mfa, 1}}
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

  # The process dictionary: the key is in x0, and a put's value in x1.
  # Each hands back the key's value (a put and an erase the old one);
  # Process.get/2's default in x1 is its answer when the key is unset.
  @dictionary_ops %{
    {:erlang, :put, 2} => "put",
    {Process, :put, 2} => "put",
    {:erlang, :get, 1} => "get",
    {Process, :get, 1} => "get",
    {Process, :get, 2} => "get",
    {:erlang, :erase, 1} => "erase",
    {Process, :delete, 1} => "erase",
    {:erlang, :erase, 0} => "erase"
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

  # Calls whose answer may be a pid of another node, and how it holds
  # them: the pid itself, a `{pid, meta}` pair, or a list of either. A
  # cluster-wide registry answers with whichever node's process holds
  # the name, and a process group with every node's members.
  @remote_answers %{
    {:global, :whereis_name, 1} => :pid,
    {:syn, :whereis, 1} => :pid,
    {:syn, :whereis_name, 1} => :pid,
    {:syn, :lookup, 2} => :pair,
    {:syn, :members, 2} => :pairs,
    {:syn, :get_members, 1} => :list,
    {:pg, :get_members, 1} => :list,
    {:pg, :get_members, 2} => :list,
    {:pg2, :get_members, 1} => :list,
    {Horde.Registry, :whereis_name, 1} => :pid,
    {Horde.Registry, :lookup, 2} => :pairs,
    {Swarm, :whereis_name, 1} => :pid,
    {Swarm, :members, 1} => :list
  }

  # The `{:via, registry, name}` registries that span nodes.
  @remote_registries [:global, :syn, Horde.Registry, Swarm]

  # BIFs that act on a process of this node only, and raise badarg when
  # handed a pid of another: the pid is in x0.
  @probes [
    {:erlang, :is_process_alive, 1},
    {Process, :alive?, 1},
    {:erlang, :process_info, 1},
    {:erlang, :process_info, 2},
    {Process, :info, 1},
    {Process, :info, 2},
    {:erlang, :garbage_collect, 1},
    {:erlang, :garbage_collect, 2},
    {:erlang, :suspend_process, 1},
    {:erlang, :suspend_process, 2},
    {:erlang, :resume_process, 1},
    {:erlang, :process_display, 2}
  ]

  # What the standard library's collection calls answer (TermFlow.Library).
  @library Library.models()

  # The Task operations on a task the caller started, by what they do
  # with it: the task (or tasks) is the first argument.
  @task_ops %{
    {Task, :await, 1} => "await",
    {Task, :await, 2} => "await",
    {Task, :await_many, 1} => "await_many",
    {Task, :await_many, 2} => "await_many",
    {Task, :yield, 1} => "yield",
    {Task, :yield, 2} => "yield",
    {Task, :yield_many, 1} => "yield_many",
    {Task, :yield_many, 2} => "yield_many",
    {Task, :shutdown, 1} => "shutdown",
    {Task, :shutdown, 2} => "shutdown",
    {Task, :ignore, 1} => "ignore"
  }

  # An exit signal, a monitor or a link, with the register naming the
  # process it goes to; and a stop: a gen behaviour's stop of the process,
  # or a supervisor's terminate_child of the child's pid (a
  # `Supervisor.terminate_child/2` of a child id names no process, and
  # resolves to none).
  @signals %{
    {Process, :exit, 2} => {"exit", {:x, 0}},
    {:erlang, :exit, 2} => {"exit", {:x, 0}},
    {GenServer, :stop, 1} => {"stop", {:x, 0}},
    {GenServer, :stop, 2} => {"stop", {:x, 0}},
    {GenServer, :stop, 3} => {"stop", {:x, 0}},
    {:gen_server, :stop, 1} => {"stop", {:x, 0}},
    {:gen_server, :stop, 3} => {"stop", {:x, 0}},
    {:gen_statem, :stop, 1} => {"stop", {:x, 0}},
    {:gen_statem, :stop, 3} => {"stop", {:x, 0}},
    {:proc_lib, :stop, 1} => {"stop", {:x, 0}},
    {:proc_lib, :stop, 3} => {"stop", {:x, 0}},
    {Agent, :stop, 1} => {"stop", {:x, 0}},
    {Agent, :stop, 2} => {"stop", {:x, 0}},
    {Agent, :stop, 3} => {"stop", {:x, 0}},
    {DynamicSupervisor, :terminate_child, 2} => {"stop", {:x, 1}},
    {Supervisor, :terminate_child, 2} => {"stop", {:x, 1}},
    {:supervisor, :terminate_child, 2} => {"stop", {:x, 1}},
    {Process, :monitor, 1} => {"monitor", {:x, 0}},
    {Process, :monitor, 2} => {"monitor", {:x, 0}},
    {:erlang, :monitor, 2} => {"monitor", {:x, 1}},
    {:erlang, :monitor, 3} => {"monitor", {:x, 1}},
    {Process, :link, 1} => {"link", {:x, 0}},
    {:erlang, :link, 1} => {"link", {:x, 0}},
    {Process, :unlink, 1} => {"unlink", {:x, 0}},
    {:erlang, :unlink, 1} => {"unlink", {:x, 0}}
  }

  # The registrations that take a conflict resolver: `:global` calls it
  # with the name and the two pids that hold it, on two nodes.
  @resolver_registrations [{:global, :register_name, 3}, {:global, :re_register_name, 3}]

  @tail_ops [:call_only, :call_last, :call_ext_only, :call_ext_last]

  # A synchronous call returns what the server's handle_call/3 replies.
  @replying_calls [
    {GenServer, :call, 2},
    {GenServer, :call, 3},
    {:gen_server, :call, 2},
    {:gen_server, :call, 3}
  ]

  @impl true
  def relations,
    do: [
      :process_start,
      :value_arg,
      :value_return,
      :value_result,
      :process_call_source,
      :process_message_source,
      :process_register_source,
      :process_send_source,
      :send_envelope,
      :process_signal_source,
      :value_object,
      :value_field,
      :value_base,
      :value_sets,
      :value_load,
      :process_remote_source,
      :process_probe_source,
      :table_alloc,
      :table_use,
      :dict_op,
      :dict_put,
      :element_fun,
      :task_op_source,
      :value_escape
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    case Helpers.reaching(module_data) do
      nil ->
        %{}

      reaching ->
        reads = ValueFlow.reads_by_function(reaching)
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
              spawns: Map.get(spawns, func_id, %{}),
              # Read only where a probe asks what guards it.
              cfg: fn -> Helpers.cfg(module_data, name, arity) end
            }

            function_facts(acc, fun)
          end
        end)
        |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    end
  end

  # ── The module, indexed per function ────────────────────────────────

  defp sites_by_function(module_data) do
    module_data
    |> CallSites.for_module()
    |> Enum.reduce(%{}, fn %{func_id: func, idx: idx} = site, acc ->
      Map.update(acc, func, %{idx => site}, &Map.put(&1, idx, site))
    end)
  end

  # The spawns Emit resolved (`spawn_call`): %{func_id => %{idx =>
  # %{runs, arity, args, shape}}}. A spawn whose target did not resolve
  # (a parameter's fun, an argument list of unknown length) is left to
  # @other_spawns, which follows a closure's register through the
  # points-to values.
  defp spawns_by_function(module_data) do
    case Helpers.typed(module_data) do
      nil ->
        %{}

      typed ->
        for %{mod: mod, func: fun, arity: arity, id: id} = row <- Map.get(typed, :spawn_call, []),
            row.source in ["closure", "fun", "mfa"],
            arity >= 0,
            shape = spawn_shape(row.api, row.variant),
            shape != nil,
            reduce: %{} do
          acc ->
            func = InstrId.func_id(id.module, id.func, id.arity)
            args = if row.args >= 0, do: {:x, row.args}, else: nil
            spawn = %{runs: "#{mod}:#{fun}/#{arity}", arity: arity, args: args, shape: shape}
            Map.update(acc, func, %{id.idx => spawn}, &Map.put(&1, id.idx, spawn))
        end
    end
  end

  # What the spawning call returns around the pid: a pid, `{pid, ref}`
  # when it monitors, `{:ok, pid}` from a proc_lib start (what init_ack
  # conventionally sends). proc_lib:start_monitor returns `{result, ref}`
  # around that, a shape not modelled.
  defp spawn_shape(api, variant) do
    cond do
      String.starts_with?(api, ":proc_lib.start_monitor/") -> nil
      String.starts_with?(api, ":proc_lib.start") -> :ok
      variant == "spawn_monitor" -> :pid_ref
      true -> :pid
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

  # %{idx => call}: every library call `Library` models, with the funs a
  # call running funs runs: one of the program's (its function ID), the
  # library's (`{:library, mfa}`), or not known (nil). A model needing a
  # literal the call does not have is no model: the call escapes.
  defp library_calls(fun) do
    for {idx, %{mfa: mfa, instrs: instrs} = site} <- fun.sites,
        not project?(site),
        {:ok, model} <- [Map.fetch(@library, mfa)],
        call = library_call(model, instrs, idx),
        into: %{},
        do: {idx, call}
  end

  defp library_call({:fun_or, at, running, plain}, instrs, idx) do
    case Resolve.fun_origin(instrs, idx, {:x, at}) do
      {kind, _fun} when kind in [:closure, :external] -> library_call(running, instrs, idx)
      _ -> library_call(plain, instrs, idx)
    end
  end

  defp library_call({:run, at, params, answer, others} = model, instrs, idx) do
    %{
      model: model,
      runs: fun_runs(instrs, idx, at),
      params: params,
      answer: answer,
      others:
        for({pos, params} <- others, do: %{runs: fun_runs(instrs, idx, pos), params: params})
    }
  end

  defp library_call({:setelement, at, _tuple, _value} = model, instrs, idx) do
    case Resolve.resolve_register(instrs, idx, {:x, at}) do
      {:ok, n} when is_integer(n) and n > 0 -> %{model: model}
      _ -> nil
    end
  end

  defp library_call(model, _instrs, _idx), do: %{model: model}

  defp fun_runs(instrs, idx, at) do
    case Resolve.fun_origin(instrs, idx, {:x, at}) do
      {:closure, closure} ->
        callee(closure)

      {:external, {mod, _name, _arity} = called} ->
        if Runtime.module?(mod), do: {:library, called}, else: callee(called)

      _ ->
        nil
    end
  end

  defp start(fun, idx, mfa, instrs) do
    cond do
      Map.has_key?(fun.spawns, idx) ->
        spawn = Map.fetch!(fun.spawns, idx)
        start = %{kind: "spawn", runs: spawn.runs, shape: spawn.shape, arity: spawn.arity}
        if spawn.args, do: Map.put(start, :args, spawn.args), else: start

      Map.has_key?(@server_starts, mfa) ->
        server_start(instrs, idx, Map.fetch!(@server_starts, mfa), :ok)

      Map.has_key?(@monitor_starts, mfa) ->
        server_start(instrs, idx, Map.fetch!(@monitor_starts, mfa), :monitor_ok)

      mfa in @child_starts ->
        with {:ok, spec} <- Resolve.resolve_register(instrs, idx, {:x, 1}),
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
    case Resolve.resolve_register(instrs, idx, {:x, pos}) do
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
             Resolve.resolve_register(instrs, idx, {:x, n}),
           {:ok, fun} when is_atom(fun) and fun != :dynamic <-
             Resolve.resolve_register(instrs, idx, {:x, n + 1}),
           {:ok, args} when is_list(args) <- Resolve.resolve_register(instrs, idx, {:x, n + 2}),
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
    case Resolve.resolve_register(instrs, idx, {:x, n}) do
      {:ok, opts} when is_list(opts) -> opts |> keyword_name() |> name_of()
      _ -> nil
    end
  end

  defp name_option(instrs, idx, {:tuple, n}) do
    case Resolve.resolve_register(instrs, idx, {:x, n}) do
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

      iex> Argus.Extractors.TermFlow.name_of(:cache)
      ":cache"

      iex> Argus.Extractors.TermFlow.name_of({:global, :cache})
      "{:global, :cache}"

      iex> Argus.Extractors.TermFlow.name_of({:via, Registry, {MyReg, :dynamic}})
      nil
  """
  @spec name_of(term()) :: String.t() | nil
  def name_of(atom) when is_atom(atom) and atom not in [nil, true, false, :dynamic],
    do: inspect(atom)

  def name_of({:global, name} = global) do
    if literal?(name), do: Terms.spell(global), else: nil
  end

  def name_of({:via, mod, key} = via) when is_atom(mod) and mod != :dynamic do
    if literal?(key), do: Terms.spell(via), else: nil
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
    fun = fun |> Map.put(:starts, starts(fun)) |> Map.put(:library, library_calls(fun))
    idxs = Enum.to_list(0..(tuple_size(fun.code) - 1)//1)

    {outs, state} =
      ValueFlow.solve(
        idxs,
        fun.reads,
        %{objs: %{}, readers: %{}},
        fn idx, outs, state ->
          result = evaluate(idx, fun, Map.put(state, :outs, outs))
          {again, state} = commit_objects(idx, result, state)
          {result.writes, state, again}
        end,
        max_evaluations: :infinity
      )

    emit(facts, fun, Map.put(state, :outs, outs))
  end

  # Records the terms the evaluation built and the ones it read a field
  # of; returns the loads to evaluate again, through a term whose fields
  # changed.
  defp commit_objects(idx, result, state) do
    Heap.commit(idx, result.objs, result.read_objs, state)
  end

  # ── What an instruction writes ───────────────────────────────────────

  defp new_result, do: %{writes: [], objs: [], read_objs: [], loads: [], unseen: MapSet.new()}

  defp evaluate(idx, fun, state) do
    ctx = %{idx: idx, fun: fun, state: state}
    instr = elem(fun.code, idx)

    case Map.fetch(fun.sites, idx) do
      {:ok, site} -> call(ctx, site, new_result())
      :error -> instruction(ctx, instr, new_result())
    end
  end

  defp instruction(ctx, :send, r), do: write(r, {:x, 0}, val(ctx, {:x, 1}))

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
        # A key not a literal is a value the map holds: under `@key`.
        fields = if sel == "*", do: add_field(fields, "@key", val(ctx, key)), else: fields
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

  defp bif(ctx, :get, [key], dst, r) do
    case dictionary_key(ctx.fun.instrs, ctx.idx, key) do
      "dynamic" -> r
      spelled -> write(r, dst, MapSet.new([{:dict, spelled}]))
    end
  end

  defp bif(_ctx, _name, _args, _dst, r), do: r

  # ── Calls ────────────────────────────────────────────────────────────

  # A call whose answer may be a pid of another node holds, beside what
  # the call is otherwise known to answer, the `remote` source of its
  # site: in the shape the answer takes.
  defp call(ctx, %{mfa: mfa, instrs: instrs} = site, r) do
    r = plain_call(ctx, site, r) |> library_answer(ctx)

    case remote_answer(instrs, ctx.idx, mfa) do
      nil -> r
      shape -> remote_result(ctx, shape, r)
    end
  end

  defp remote_answer(instrs, idx, mfa) do
    case Map.fetch(@remote_answers, mfa) do
      {:ok, shape} -> shape
      :error -> remote_answer_of(instrs, idx, mfa)
    end
  end

  # GenServer.whereis/1 of a cluster-wide name, and the callers a Task or
  # an erpc'd process carries, which may be on the node that started it.
  defp remote_answer_of(instrs, idx, {GenServer, :whereis, 1}) do
    case Resolve.resolve_register(instrs, idx, {:x, 0}) do
      {:ok, {:global, _}} -> :pid
      {:ok, {:via, registry, _}} when registry in @remote_registries -> :pid
      _ -> nil
    end
  end

  defp remote_answer_of(instrs, idx, {mod, :get, arity})
       when (mod == Process and arity in [1, 2]) or (mod == :erlang and arity == 1) do
    case Resolve.resolve_register(instrs, idx, {:x, 0}) do
      {:ok, :"$callers"} -> :list
      _ -> nil
    end
  end

  # A process's links: `{:links, pids}`, any of them another node's.
  defp remote_answer_of(instrs, idx, {mod, :info, 2}) when mod == Process,
    do: links_answer(instrs, idx)

  defp remote_answer_of(instrs, idx, {:erlang, :process_info, 2}),
    do: links_answer(instrs, idx)

  defp remote_answer_of(_instrs, _idx, _mfa), do: nil

  defp links_answer(instrs, idx) do
    case Resolve.resolve_register(instrs, idx, {:x, 1}) do
      {:ok, :links} -> :tagged_list
      _ -> nil
    end
  end

  defp remote_result(ctx, shape, r) do
    remote = MapSet.new([{:remote, ctx.idx}])

    {value, r} =
      case shape do
        :pid -> {remote, r}
        :pair -> remote_pair(ctx, remote, r)
        :list -> remote_list(ctx, remote, r)
        :pairs -> remote_pairs(ctx, remote, r)
        :tagged_list -> remote_tagged_list(ctx, remote, r)
      end

    %{r | writes: add_to_write(r.writes, "x0", value)}
  end

  # Objects at a site are keyed `idx` and `{idx, n}`: 1 is a start's
  # inner pair; these take 2 and 3.
  defp remote_pair(ctx, remote, r) do
    pair = %{
      shape: "tuple",
      fields: %{"{0}" => remote},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: "",
      arity: 2
    }

    {obj_token({ctx.idx, 3}), object(r, {ctx.idx, 3}, pair)}
  end

  defp remote_list(ctx, element, r) do
    list = %{
      shape: "list",
      fields: %{"[]" => element},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: "",
      arity: 0,
      nil_tail: true
    }

    {obj_token({ctx.idx, 2}), object(r, {ctx.idx, 2}, list)}
  end

  # `{:links, pids}`: the list in the second element.
  defp remote_tagged_list(ctx, remote, r) do
    {list, r} = remote_list(ctx, remote, r)

    tagged = %{
      shape: "tuple",
      fields: %{"{1}" => list},
      base: MapSet.new(),
      keys: MapSet.new(),
      tag: "",
      arity: 2
    }

    {obj_token({ctx.idx, 3}), object(r, {ctx.idx, 3}, tagged)}
  end

  defp remote_pairs(ctx, remote, r) do
    {pair, r} = remote_pair(ctx, remote, r)
    remote_list(ctx, pair, r)
  end

  # What a call `Library` models answers, written into x0 beside what
  # the call is otherwise known to answer. A call running one of the
  # program's funs answers with the fun's answers as this call's `result`
  # source, whose callee is the fun (`answering/2`); one running a
  # library function the table models applies that model to what the
  # function is handed. The funs' parameters are evaluated here too, so
  # the terms they build (a map's pairs) are committed for emission.
  defp library_answer(r, ctx) do
    case Map.fetch(ctx.fun.library, ctx.idx) do
      {:ok, %{runs: runs, params: params, answer: answer} = call} ->
        {values, r} = lib_values(ctx, params, run_env(ctx, runs), [1], r)

        r =
          call.others
          |> Enum.with_index()
          |> Enum.reduce(r, fn {other, j}, r ->
            ctx |> lib_values(other.params, direct(ctx), [2, j], r) |> elem(1)
          end)

        case run_result(ctx, runs, values, r) do
          {:ok, result, r} ->
            {value, r} = lib_value(ctx, answer, %{direct(ctx) | result: result}, [0], r)
            %{r | writes: add_to_write(r.writes, "x0", value)}

          :unknown ->
            r
        end

      {:ok, %{model: model}} ->
        {value, r} = lib_value(ctx, model, direct(ctx), [0], r)
        %{r | writes: add_to_write(r.writes, "x0", value)}

      :error ->
        r
    end
  end

  # What the fun a library call runs answers.
  defp run_result(ctx, runs, _values, r) when is_binary(runs),
    do: {:ok, MapSet.new([{:result, ctx.idx}]), r}

  defp run_result(ctx, {:library, called}, values, r) do
    cond do
      acts_on_elements?(called) ->
        {:ok, MapSet.new(), r}

      model = plain_model(called) ->
        args = %{direct(ctx) | arg: fn n -> Enum.at(values, n, MapSet.new()) end, literal: false}
        {value, r} = lib_value(ctx, model, args, [3], r)
        {:ok, value, r}

      true ->
        :unknown
    end
  end

  defp run_result(_ctx, _runs, _values, _r), do: :unknown

  # A library function captured as the fun whose effect on each element
  # is recorded where it is (a Task operation, a signal, a probe), not
  # what it answers.
  defp acts_on_elements?(called),
    do: Map.has_key?(@task_ops, called) or Map.has_key?(@signals, called) or called in @probes

  # The library function's own model, when it is a spec: one running a
  # fun of its own is not applied to an element.
  defp plain_model(called) do
    case Map.fetch(@library, called) do
      {:ok, {:run, _, _, _, _}} -> nil
      {:ok, {:fun_or, _, _, _}} -> nil
      {:ok, model} -> model
      :error -> nil
    end
  end

  # The arguments of the call itself, read from its registers.
  defp direct(ctx),
    do: %{arg: &val(ctx, {:x, &1}), result: MapSet.new(), literal: true}

  # The same, and what one of the program's funs the call runs answers: a
  # fold's accumulator is handed it back.
  defp run_env(ctx, runs) when is_binary(runs),
    do: %{direct(ctx) | result: MapSet.new([{:result, ctx.idx}])}

  defp run_env(ctx, _runs), do: direct(ctx)

  defp lib_values(ctx, specs, env, path, r) do
    {values, r} =
      specs
      |> Enum.with_index()
      |> Enum.reduce({[], r}, fn {spec, i}, {acc, r} ->
        {value, r} = lib_value(ctx, spec, env, path ++ [i], r)
        {[value | acc], r}
      end)

    {Enum.reverse(values), r}
  end

  # The value a `Library` spec stands for at this call. Terms it builds
  # are allocated at the call, keyed by the spec's path, so evaluation
  # and emission name the same ones.
  defp lib_value(_ctx, {:arg, n}, env, _path, r), do: {env.arg.(n), r}
  defp lib_value(_ctx, :result, env, _path, r), do: {env.result, r}
  defp lib_value(_ctx, :none, _env, _path, r), do: {MapSet.new(), r}

  defp lib_value(ctx, {:union, specs}, env, path, r) do
    {values, r} = lib_values(ctx, specs, env, path, r)
    {Enum.reduce(values, MapSet.new(), &MapSet.union/2), r}
  end

  defp lib_value(ctx, {:elements, spec}, env, path, r) do
    {value, r} = lib_value(ctx, spec, env, path ++ [0], r)
    elements(ctx, value, path, r)
  end

  defp lib_value(ctx, {:read, spec, sel}, env, path, r) do
    {value, r} = lib_value(ctx, spec, env, path ++ [0], r)
    load(ctx, value, sel, lib_load_id(ctx, path, sel), r)
  end

  defp lib_value(ctx, {:list, spec}, env, path, r) do
    {value, r} = lib_value(ctx, spec, env, path ++ [0], r)
    lib_object(ctx, path, %{shape: "list", fields: %{"[]" => value}, base: MapSet.new()}, r)
  end

  defp lib_value(ctx, {:cons, head, tail}, env, path, r) do
    {[head, tail], r} = lib_values(ctx, [head, tail], env, path, r)
    lib_object(ctx, path, %{shape: "list", fields: %{"[]" => head}, base: tail}, r)
  end

  defp lib_value(ctx, {:tuple, specs, tag}, env, path, r) do
    {fields, r} =
      specs
      |> Enum.with_index()
      |> Enum.reduce({%{}, r}, fn
        {nil, _i}, acc ->
          acc

        {spec, i}, {fields, r} ->
          {value, r} = lib_value(ctx, spec, env, path ++ [i], r)
          {Map.put(fields, "{#{i}}", value), r}
      end)

    obj = %{shape: "tuple", fields: fields, base: MapSet.new(), tag: tag, arity: length(specs)}
    lib_object(ctx, path, obj, r)
  end

  defp lib_value(ctx, {:map, keys, values}, env, path, r) do
    {[keys, values], r} = lib_values(ctx, [keys, values], env, path, r)

    lib_object(
      ctx,
      path,
      %{shape: "map", fields: %{"@key" => keys, "*" => values}, base: MapSet.new()},
      r
    )
  end

  defp lib_value(ctx, {:put, map, at, value}, env, path, r) do
    {[map, value], r} = lib_values(ctx, [map, value], env, path, r)
    sel = if env.literal, do: literal_selector(ctx.fun.instrs, ctx.idx, at), else: "*"
    key = if sel == "*" and env.literal, do: val(ctx, {:x, at}), else: MapSet.new()

    obj = %{
      shape: "map",
      fields: %{sel => value, "@key" => key},
      base: map,
      keys: if(sel == "*", do: [], else: [sel])
    }

    lib_object(ctx, path, obj, r)
  end

  defp lib_value(ctx, {:field, map, at}, env, path, r) do
    {map, r} = lib_value(ctx, map, env, path ++ [0], r)
    sel = if env.literal, do: literal_selector(ctx.fun.instrs, ctx.idx, at), else: "*"
    load(ctx, map, sel, lib_load_id(ctx, path, sel), r)
  end

  defp lib_value(ctx, {:index, tuple, at}, env, path, r) do
    {tuple, r} = lib_value(ctx, tuple, env, path ++ [0], r)

    sel =
      case env.literal and Resolve.resolve_register(ctx.fun.instrs, ctx.idx, {:x, at}) do
        {:ok, n} when is_integer(n) and n > 0 -> "{#{n - 1}}"
        _ -> "**"
      end

    load(ctx, tuple, sel, lib_load_id(ctx, path, sel), r)
  end

  defp lib_value(ctx, {:setelement, at, tuple, value}, env, path, r) do
    {[tuple, value], r} = lib_values(ctx, [tuple, value], env, path, r)
    {:ok, n} = Resolve.resolve_register(ctx.fun.instrs, ctx.idx, {:x, at})
    sel = "{#{n - 1}}"
    obj = %{shape: "tuple", fields: %{sel => value}, base: tuple, keys: [sel]}
    lib_object(ctx, path, obj, r)
  end

  defp lib_value(ctx, {:into, elements, at}, env, path, r) do
    target =
      if env.literal,
        do: Resolve.resolve_register(ctx.fun.instrs, ctx.idx, {:x, at}),
        else: :dynamic

    spec =
      case target do
        {:ok, []} ->
          {:list, elements}

        {:ok, map} when map == %{} ->
          {:map, {:read, elements, "{0}"}, {:read, elements, "{1}"}}

        _ ->
          {:union,
           [
             {:list, elements},
             {:map, {:read, elements, "{0}"}, {:read, elements, "{1}"}},
             {:arg, at}
           ]}
      end

    lib_value(ctx, spec, env, path ++ [0], r)
  end

  defp lib_object(ctx, path, obj, r) do
    key = {ctx.idx, {:lib, path}}

    obj =
      obj
      |> Map.update(:keys, MapSet.new(), &MapSet.new/1)
      |> Map.put_new(:tag, "")
      |> Map.put_new(:arity, 0)
      |> Map.update!(:fields, fn fields ->
        Map.reject(fields, fn {_sel, v} -> MapSet.size(v) == 0 end)
      end)

    {obj_token(key), object(r, key, obj)}
  end

  defp lib_load_id(ctx, path, sel),
    do: site(ctx.fun, ctx.idx) <> " " <> sel <> " @" <> Enum.map_join(path, ".", &path_step/1)

  # What enumerating `value` yields: a list's elements, a map's
  # {key, value} pairs — a pair this call allocates for a map built here,
  # one points-to stands for (`pair <map>`) for a map from elsewhere,
  # read as the `[]` load of it.
  defp elements(ctx, value, path, r) do
    {maps, others} =
      Enum.split_with(value, fn
        {:obj, key} -> match?(%{shape: "map"}, Map.get(ctx.state.objs, key))
        _ -> false
      end)

    {listed, r} = load(ctx, MapSet.new(others), "[]", lib_load_id(ctx, path, "[]"), r)

    Enum.reduce(maps, {listed, r}, fn {:obj, key}, {acc, r} ->
      {pairs, r} = map_pairs(ctx, key, path, r, %{})
      {MapSet.union(acc, pairs), r}
    end)
  end

  defp map_pairs(ctx, key, path, r, seen) do
    obj = Map.fetch!(ctx.state.objs, key)
    r = %{r | read_objs: [key | r.read_objs]}
    seen = Map.put(seen, key, true)
    {keys, fields} = Map.pop(obj.fields, "@key", MapSet.new())
    values = fields |> Map.values() |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    {pair, r} =
      lib_object(
        ctx,
        path ++ [{:pair, obj_id(ctx.fun, key)}],
        %{
          shape: "tuple",
          fields: %{"{0}" => keys, "{1}" => values},
          base: MapSet.new(),
          arity: 2
        },
        r
      )

    # The base's pairs too: a map built here, by its own pairs; anything
    # else, by the `[]` load points-to resolves.
    {local, other} =
      obj.base
      |> Enum.reject(fn token -> match?({:obj, base} when is_map_key(seen, base), token) end)
      |> Enum.split_with(fn
        {:obj, base} -> match?(%{shape: "map"}, Map.get(ctx.state.objs, base))
        _token -> false
      end)

    {inherited, r} =
      Enum.reduce(local, {MapSet.new(), r}, fn {:obj, base}, {acc, r} ->
        {more, r} = map_pairs(ctx, base, path, r, seen)
        {MapSet.union(acc, more), r}
      end)

    {loaded, r} =
      load(
        ctx,
        MapSet.new(other),
        "[]",
        lib_load_id(ctx, path ++ [{:base, obj_id(ctx.fun, key)}], "[]"),
        r
      )

    {pair |> MapSet.union(inherited) |> MapSet.union(loaded), r}
  end

  defp add_to_write(writes, reg, value) do
    case List.keyfind(writes, reg, 0) do
      nil -> [{reg, value} | writes]
      {^reg, old} -> List.keyreplace(writes, reg, 0, {reg, MapSet.union(old, value)})
    end
  end

  defp plain_call(ctx, %{mfa: mfa, instrs: instrs} = site, r) do
    idx = ctx.idx

    cond do
      Map.has_key?(ctx.fun.starts, idx) ->
        start_result(ctx, Map.fetch!(ctx.fun.starts, idx), r)

      mfa == {:erlang, :send, 2} ->
        write(r, {:x, 0}, val(ctx, {:x, 1}))

      mfa == {:ets, :new, 2} ->
        write(r, {:x, 0}, MapSet.new([{:table, table(ctx.fun, idx)}]))

      Map.has_key?(@lookups, mfa) ->
        write(r, {:x, 0}, lookup(ctx, instrs, idx, Map.fetch!(@lookups, mfa)))

      mfa == {Registry, :lookup, 2} ->
        registry_lookup(ctx, instrs, r)

      Map.has_key?(@dictionary_ops, mfa) ->
        write(r, {:x, 0}, dictionary_value(ctx, mfa))

      Map.has_key?(@field_reads, mfa) ->
        {term, key} = Map.fetch!(@field_reads, mfa)
        {value, r} = library_load(ctx, term, key, r)
        value = if elem(mfa, 2) == 3, do: MapSet.union(value, val(ctx, {:x, 2})), else: value
        write(r, {:x, 0}, value)

      Map.has_key?(@wrapped_field_reads, mfa) ->
        {term, key} = Map.fetch!(@wrapped_field_reads, mfa)
        {value, r} = library_load(ctx, term, key, r)
        ok_tuple(ctx, value, r)

      Map.has_key?(@field_writes, mfa) ->
        field_write(ctx, instrs, Map.fetch!(@field_writes, mfa), r)

      mfa in @replying_calls ->
        write(r, {:x, 0}, MapSet.new([{:reply, idx}]))

      project?(site) ->
        write(r, {:x, 0}, MapSet.new([{:result, idx}]))

      true ->
        r
    end
  end

  # Map.put/3 and :maps.put/3: the map with the field set, its key held
  # under `@key` when it is not a literal.
  defp field_write(ctx, instrs, {term, key, value}, r) do
    sel = literal_selector(instrs, ctx.idx, key)
    fields = %{sel => val(ctx, {:x, value})}
    fields = if sel == "*", do: add_field(fields, "@key", val(ctx, {:x, key})), else: fields

    obj = %{
      shape: "map",
      fields: fields,
      base: val(ctx, {:x, term}),
      keys: if(sel == "*", do: MapSet.new(), else: MapSet.new([sel])),
      tag: "",
      arity: 0
    }

    r |> object(ctx.idx, obj) |> write({:x, 0}, obj_token(ctx.idx))
  end

  # What a lookup of the name in x0 returns: the pid registered under it.
  # GenServer.whereis/1 takes any server reference, a pid included.
  defp lookup(ctx, instrs, idx, registry) do
    case Resolve.resolve_register(instrs, idx, {:x, 0}) do
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

  # What a dictionary call hands back: the value kept under its literal
  # key (none for erase/0 or a key not known), and Process.get/2's
  # default.
  defp dictionary_value(ctx, mfa) do
    kept =
      case dictionary_key(ctx.fun.instrs, ctx.idx, {:x, 0}) do
        "dynamic" -> []
        _spelled when mfa == {:erlang, :erase, 0} -> []
        spelled -> [{:dict, spelled}]
      end

    default = if mfa == {Process, :get, 2}, do: Enum.to_list(val(ctx, {:x, 1})), else: []
    MapSet.new(kept ++ default)
  end

  # A dictionary key as the rows spell it: a literal term, or `dynamic`.
  defp dictionary_key(_instrs, _idx, {:atom, atom}), do: key_spelling(atom)
  defp dictionary_key(_instrs, _idx, {:integer, n}), do: key_spelling(n)
  defp dictionary_key(_instrs, _idx, {:literal, term}), do: key_spelling(term)

  defp dictionary_key(instrs, idx, operand) do
    case Resolve.resolve_register(instrs, idx, operand) do
      {:ok, term} -> key_spelling(term)
      _ -> "dynamic"
    end
  end

  defp key_spelling(term) do
    if term not in [nil, true, false] and literal?(term), do: Terms.spell(term), else: "dynamic"
  end

  # `Registry.lookup(reg, key)` returns `[{pid, value}]`: a list whose
  # elements are tuples holding the pid registered under the key.
  defp registry_lookup(ctx, instrs, r) do
    idx = ctx.idx

    with {:ok, registry} <- Resolve.resolve_register(instrs, idx, {:x, 0}),
         {:ok, key} <- Resolve.resolve_register(instrs, idx, {:x, 1}),
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

  defp start_result(_ctx, %{shape: :none}, r), do: r

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

        ValueFlow.input(ctx.fun.reads, ctx.state.outs, ctx.idx, reg, &{:param, &1})

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

  defp add_field(fields, sel, value) do
    if MapSet.size(value) == 0,
      do: fields,
      else: Map.update(fields, sel, value, &MapSet.union(&1, value))
  end

  defp obj_token(key), do: MapSet.new([{:obj, key}])

  defp load_id(ctx, sel), do: site(ctx.fun, ctx.idx) <> " " <> sel

  # Reads field `sel` of every term in `value`. A term built here is read
  # directly (its field, a map's unknown-key field, and the base's field
  # when the term does not set it); a term from elsewhere becomes a load
  # the Datalog resolves; a pid has no fields.
  #
  # A read with an unknown key follows only the unknown-key field: what a
  # map built here holds under a literal key it may return goes where
  # value flow does not follow (`unseen`, emitted as `value_escape`).
  defp load(ctx, value, sel, id, r) do
    {sources, dependencies, loads} = Heap.read(ctx.state.objs, value, sel, id)
    r = %{r | read_objs: dependencies ++ r.read_objs, loads: loads ++ r.loads}

    if sel == "*",
      do: {sources, %{r | unseen: MapSet.union(r.unseen, Heap.unseen(ctx.state.objs, value))}},
      else: {sources, r}
  end

  # A map key as a field name: the inspected literal, or `*`.
  defp selector({:atom, atom}), do: inspect(atom)
  defp selector({:integer, n}), do: inspect(n)
  defp selector({:float, f}), do: inspect(f)
  defp selector({:literal, term}), do: Terms.spell(term)
  defp selector(nil), do: inspect([])
  defp selector(_register), do: "*"

  defp literal_selector(instrs, idx, pos) do
    case Resolve.resolve_register(instrs, idx, {:x, pos}) do
      {:ok, key} when key != :dynamic -> Terms.spell(key)
      _ -> "*"
    end
  end

  # ── Emission ─────────────────────────────────────────────────────────

  defp emit(facts, fun, state) do
    live = Heap.live(state.objs)
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
        nil ->
          acc

        name ->
          add_fact(acc, :process_register_source, [id, fun.func_id, name, "proc", start.proc])
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

  defp emit_objects(facts, ctx) do
    func = ctx.fun.func_id

    Enum.reduce(Map.keys(ctx.live), facts, fn key, acc ->
      obj = Map.fetch!(ctx.state.objs, key)
      id = obj_id(ctx.fun, key)
      acc = add_fact(acc, :value_object, [func, id, obj.shape, obj.tag, to_string(obj.arity)])

      acc =
        Enum.reduce(obj.fields, acc, fn {sel, value}, inner ->
          sources(inner, ctx, :value_field, [func, id, sel], value)
        end)

      acc = sources(acc, ctx, :value_base, [func, id], obj.base)

      if convert(ctx, obj.base) == [],
        do: acc,
        else: Enum.reduce(obj.keys, acc, &add_fact(&2, :value_sets, [id, &1]))
    end)
  end

  defp emit_instructions(facts, ctx) do
    fun = ctx.fun

    Enum.reduce(0..(tuple_size(fun.code) - 1)//1, facts, fn idx, acc ->
      ictx = %{idx: idx, fun: fun, state: ctx.state}
      result = evaluate(idx, fun, ctx.state)
      at = Map.put(ctx, :idx, idx)

      acc = emit_loads(acc, at, result)

      case Map.fetch(fun.sites, idx) do
        {:ok, site} -> emit_site(acc, at, ictx, site)
        :error -> emit_other(acc, at, ictx, elem(fun.code, idx))
      end
    end)
  end

  defp emit_other(facts, at, ictx, :return),
    do: sources(facts, at, :value_return, [at.fun.func_id], val(ictx, {:x, 0}))

  defp emit_other(facts, at, ictx, :send) do
    facts
    |> send_row(at, ictx)
    |> sources(at, :value_escape, [site(at.fun, at.idx), at.fun.func_id], val(ictx, {:x, 1}))
  end

  # A fun called or a function applied where the call names neither: its
  # arguments go where no summary says.
  defp emit_other(facts, at, ictx, {:call_fun, arity}), do: escape_args(facts, at, ictx, arity)

  defp emit_other(facts, at, ictx, {:call_fun2, _tag, arity, _fun}),
    do: escape_args(facts, at, ictx, arity)

  defp emit_other(facts, at, ictx, {:apply, arity}), do: escape_args(facts, at, ictx, arity)

  defp emit_other(facts, at, ictx, {:apply_last, arity, _dealloc}),
    do: escape_args(facts, at, ictx, arity)

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
        :value_arg,
        [site(at.fun, at.idx), at.fun.func_id, closure, to_string(first + slot), "closure"],
        val(ictx, operand)
      )
    end)
  end

  defp emit_other(facts, at, _ictx, {:bif, :get, _fail, [key], _dst}) do
    spelled = dictionary_key(at.fun.instrs, at.idx, key)
    add_fact(facts, :dict_op, [site(at.fun, at.idx), at.fun.func_id, "get", spelled])
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
    |> emit_table(at, ictx, mfa)
    |> emit_dictionary(at, ictx, mfa)
    |> emit_remote(at, mfa)
    |> emit_probe(at, ictx, mfa)
    |> emit_resolver(at, mfa)
    |> emit_library(at, ictx)
    |> emit_task_op(at, ictx, mfa)
    |> emit_escape(at, ictx, site)
    |> emit_tail(at, ictx, site)
  end

  # ── Funs run on elements, Task operations and escapes ───────────────

  # A library call running funs on elements (`Library`'s `:run`): each
  # of the program's funs it runs is handed its parameters as `element`
  # value_args; a Task operation the library's fun is does to what it is
  # handed. Any other fun, or one not known, leaves the call's arguments
  # to `emit_escape/4`.
  defp emit_library(facts, at, ictx) do
    case Map.fetch(at.fun.library, at.idx) do
      {:ok, %{runs: runs, params: params, answer: answer} = call} ->
        answers = if Library.answer_kept?(answer), do: "kept", else: "dropped"
        facts = run_rows(facts, at, ictx, {runs, answers}, params, [1])

        # A further fun's answers are the call's own business (a key fun's
        # keys): not known to be dropped.
        call.others
        |> Enum.with_index()
        |> Enum.reduce(facts, fn {other, j}, acc ->
          run_rows(acc, at, ictx, {other.runs, "kept"}, other.params, [2, j])
        end)

      _ ->
        facts
    end
  end

  defp run_rows(facts, at, ictx, {runs, answers}, params, path) when is_binary(runs) do
    id = site(at.fun, at.idx)
    func = at.fun.func_id
    {values, r} = lib_values(ictx, params, run_env(ictx, runs), path, new_result())

    values
    |> Enum.with_index()
    |> Enum.reduce(
      facts |> add_fact(:element_fun, [id, func, runs, answers]) |> emit_loads(at, r),
      fn {value, i}, acc ->
        sources(acc, at, :value_arg, [id, func, runs, to_string(i), "element"], value)
      end
    )
  end

  defp run_rows(facts, at, ictx, {{:library, called}, _answers}, [_ | _] = params, path) do
    {values, r} = lib_values(ictx, params, direct(ictx), path, new_result())

    cond do
      Map.has_key?(@task_ops, called) ->
        facts |> emit_loads(at, r) |> task_op_rows(at, Map.fetch!(@task_ops, called), hd(values))

      # A signal captured as the fun (`&Process.monitor/1`) goes to each
      # element it is handed.
      Map.has_key?(@signals, called) ->
        {signal, {:x, n}} = Map.fetch!(@signals, called)
        target = Enum.at(values, n, MapSet.new())

        facts
        |> emit_loads(at, r)
        |> sources(
          at,
          :process_signal_source,
          [site(at.fun, at.idx), at.fun.func_id, signal],
          target
        )

      # A local-only BIF captured as the fun is itself the probe, at this
      # call, of each element.
      called in @probes ->
        value =
          values
          |> hd()
          |> MapSet.filter(&match?({kind, _} when kind in [:remote, :param, :result, :load], &1))

        facts
        |> emit_loads(at, r)
        |> sources(
          at,
          :process_probe_source,
          [site(at.fun, at.idx), at.fun.func_id, spell(called)],
          value
        )

      true ->
        facts
    end
  end

  defp run_rows(facts, _at, _ictx, _runs, _params, _path), do: facts

  defp emit_task_op(facts, at, ictx, mfa) do
    case Map.fetch(@task_ops, mfa) do
      {:ok, op} -> task_op_rows(facts, at, op, val(ictx, {:x, 0}))
      :error -> facts
    end
  end

  defp task_op_rows(facts, at, op, value),
    do: sources(facts, at, :task_op_source, [site(at.fun, at.idx), at.fun.func_id, op], value)

  # Every argument of a call outside the program that value flow does not
  # follow through: the term it is handed may be kept, sent or dropped
  # where no summary says.
  defp emit_escape(facts, at, ictx, %{mfa: {_mod, _fun, arity} = mfa} = site) do
    if project?(site) or followed?(at, ictx, mfa),
      do: facts,
      else: escape_args(facts, at, ictx, arity)
  end

  defp escape_args(facts, at, ictx, arity) do
    Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
      sources(
        acc,
        at,
        :value_escape,
        [site(at.fun, at.idx), at.fun.func_id],
        val(ictx, {:x, pos})
      )
    end)
  end

  defp followed?(at, ictx, mfa) do
    cond do
      Map.has_key?(@task_ops, mfa) -> true
      Map.has_key?(@field_reads, mfa) or Map.has_key?(@wrapped_field_reads, mfa) -> true
      Map.has_key?(@field_writes, mfa) or Map.has_key?(@lookups, mfa) -> true
      Map.has_key?(@dictionary_ops, mfa) -> kept_in_dictionary?(at, ictx, mfa)
      true -> followed_library?(Map.get(at.fun.library, at.idx))
    end
  end

  # A put under a key not known is a value no `dict_put` row keeps.
  defp kept_in_dictionary?(at, _ictx, mfa) do
    Map.fetch!(@dictionary_ops, mfa) != "put" or
      dictionary_key(at.fun.instrs, at.idx, {:x, 0}) != "dynamic"
  end

  defp followed_library?(%{runs: runs, others: others}),
    do: Enum.all?([runs | Enum.map(others, & &1.runs)], &followed_fun?/1)

  defp followed_library?(%{model: _model}), do: true
  defp followed_library?(nil), do: false

  defp followed_fun?(runs) when is_binary(runs), do: true

  defp followed_fun?({:library, called}),
    do: acts_on_elements?(called) or plain_model(called) != nil

  defp followed_fun?(_runs), do: false

  # ── Pids of other nodes ──────────────────────────────────────────────
  #
  # A pid a cluster-wide registry or a process group answers with may be
  # another node's, and a few BIFs act on a local process only. The
  # `remote` source of a site is what such a call answered; these rows
  # say where those sources come from and where a local-only BIF is
  # handed a pid, and `clientlib/remote_pids.dl` joins the two. No
  # process is allocated: the points-to rules resolve no `remote`
  # source, so the stage's rows are the same with them or without them.

  defp emit_remote(facts, at, mfa) do
    case remote_answer(at.fun.instrs, at.idx, mfa) do
      nil ->
        facts

      _shape ->
        add_fact(facts, :process_remote_source, [site(at.fun, at.idx), at.fun.func_id, spell(mfa)])
    end
  end

  # A local-only BIF, handed a value that may be a pid of another node:
  # one it looked up, a parameter, a callee's result or a field it read.
  # A probe on the arm where a test found `node(pid)` equal to this node
  # is left out: the program asked where the pid lives first.
  defp emit_probe(facts, at, ictx, mfa) do
    if mfa in @probes do
      value =
        ictx
        |> val({:x, 0})
        |> MapSet.filter(&match?({kind, _} when kind in [:remote, :param, :result, :load], &1))

      if MapSet.size(value) == 0 or node_tested?(at.fun, at.idx) do
        facts
      else
        sources(
          facts,
          at,
          :process_probe_source,
          [site(at.fun, at.idx), at.fun.func_id, spell(mfa)],
          value
        )
      end
    else
      facts
    end
  end

  # Whether a test finding `node(p)` equal to another node, for a `p` that
  # may be the pid in x0, decides that `idx` runs: `if node(pid) ==
  # node()`, in a head or a body, with the probe on the arm where the two
  # are equal (the pass edge of an equality test, the fail edge of an
  # inequality). A probe on the other arm runs exactly when the pid is
  # elsewhere, and one after the arms join runs either way: neither is
  # guarded.
  defp node_tested?(fun, idx) do
    pid = MapSet.new(Resolve.writers(fun.instrs, idx, {:x, 0}))

    with true <- MapSet.size(pid) > 0,
         %Graph{} = cfg <- fun.cfg.(),
         %{id: probe} <- Graph.block_at(cfg, idx) do
      Enum.any?(0..(tuple_size(fun.code) - 1)//1, fn t ->
        case node_test(fun, t, pid) do
          nil -> false
          equal -> on_arm?(cfg, t, equal, probe)
        end
      end)
    else
      _ -> false
    end
  end

  # The test at `t` ends its block; its `equal` edge leads to a block that
  # only that edge enters, and that block dominates the probe's.
  defp on_arm?(cfg, t, equal, probe) do
    with %{id: test, range: {_, ^t}, succs: succs} <- Graph.block_at(cfg, t),
         [arm] <- for({to, ^equal} <- succs, do: to),
         %{preds: [{^test, ^equal}]} <- Map.get(cfg.blocks, arm) do
      Graph.dominates?(cfg, arm, probe)
    else
      _ -> false
    end
  end

  # The edge on which a node test found the two nodes equal, or nil.
  @node_tests %{
    is_eq_exact: :branch_pass,
    is_eq: :branch_pass,
    is_ne_exact: :branch_fail,
    is_ne: :branch_fail
  }

  defp node_test(fun, t, pid) do
    with {:test, op, _fail, [_, _] = operands} <- elem(fun.code, t),
         {:ok, equal} <- Map.fetch(@node_tests, op),
         true <- Enum.any?(operands, &node_of?(fun, t, &1, pid)) do
      equal
    else
      _ -> nil
    end
  end

  defp node_of?(fun, t, operand, pid) do
    case register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        fun.instrs
        |> Resolve.writers(t, reg)
        |> Enum.any?(fn
          at when is_integer(at) ->
            case elem(fun.code, at) do
              {:bif, :node, _fail, [arg], _dst} ->
                not MapSet.disjoint?(MapSet.new(Resolve.writers(fun.instrs, at, arg)), pid)

              _ ->
                false
            end

          {:param, _k} ->
            false
        end)

      _literal ->
        false
    end
  end

  # A conflict resolver: `:global` calls it with the name and the two
  # pids that hold it, one of them on another node. Its second and third
  # parameters are filled with the registration's `remote` source.
  defp emit_resolver(facts, at, mfa) do
    with true <- mfa in @resolver_registrations,
         resolver when resolver != nil <- resolver(at.fun.instrs, at.idx) do
      id = site(at.fun, at.idx)

      facts
      |> add_fact(:process_remote_source, [id, at.fun.func_id, spell(mfa)])
      |> add_fact(:value_arg, [id, at.fun.func_id, resolver, "1", "resolver", "remote", id])
      |> add_fact(:value_arg, [id, at.fun.func_id, resolver, "2", "resolver", "remote", id])
    else
      _ -> facts
    end
  end

  defp resolver(instrs, idx) do
    case Resolve.fun_origin(instrs, idx, {:x, 2}) do
      {:closure, {mod, name, arity}} ->
        Normalize.func_id(mod, name, arity)

      {:external, {mod, name, arity}} ->
        if Runtime.module?(mod), do: nil, else: Normalize.func_id(mod, name, arity)

      _ ->
        nil
    end
  end

  defp spell({mod, fun, arity}), do: Exception.format_mfa(mod, fun, arity)

  # An ETS table is an object too, allocated by the `:ets.new/2` that made
  # it: the reference an unnamed table is, or the name a named table is
  # answered with. Every other `:ets` call names its table in x0.
  defp emit_table(facts, at, _ictx, {:ets, :new, 2}) do
    add_fact(facts, :table_alloc, [site(at.fun, at.idx), at.fun.func_id, table(at.fun, at.idx)])
  end

  defp emit_table(facts, at, ictx, {:ets, _func, arity}) when arity > 0 do
    sources(facts, at, :table_use, [site(at.fun, at.idx), at.fun.func_id], val(ictx, {:x, 0}))
  end

  defp emit_table(facts, _at, _ictx, _mfa), do: facts

  # The process dictionary: every put, get and erase, and what a put
  # keeps under a literal key. erase/0 erases every key: a key not known.
  defp emit_dictionary(facts, at, ictx, mfa) do
    case Map.fetch(@dictionary_ops, mfa) do
      {:ok, op} ->
        id = site(at.fun, at.idx)

        key =
          if mfa == {:erlang, :erase, 0},
            do: "dynamic",
            else: dictionary_key(at.fun.instrs, at.idx, {:x, 0})

        facts = add_fact(facts, :dict_op, [id, at.fun.func_id, op, key])

        if op == "put" and key != "dynamic",
          do: sources(facts, at, :dict_put, [id, at.fun.func_id, key], val(ictx, {:x, 1})),
          else: facts

      :error ->
        facts
    end
  end

  # Every argument of a call into project code.
  defp emit_args(facts, at, ictx, %{mfa: {_m, _f, arity} = mfa} = site) do
    if project?(site) do
      Enum.reduce(0..(arity - 1)//1, facts, fn pos, acc ->
        sources(
          acc,
          at,
          :value_arg,
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
      :value_arg,
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
      :value_arg,
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
            :value_arg,
            [site(at.fun, at.idx), at.fun.func_id, runs, to_string(pos), "spawn"],
            value
          )
        end)

      :unknown ->
        facts
    end
  end

  defp emit_start_args(facts, _at, _ictx, _start), do: facts

  defp list_elements(ictx, value), do: Heap.list_elements(ictx.state.objs, value)

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
    |> sources(at, :process_call_source, [id, at.fun.func_id, kind], destination(at, ictx))
    |> sources(at, :process_message_source, [id, at.fun.func_id, kind], val(ictx, {:x, 1}))
  end

  defp destination(at, ictx, reg \\ {:x, 0}) do
    value = val(ictx, reg)

    with {:ok, term} <- Resolve.resolve_register(at.fun.instrs, at.idx, reg),
         name when name != nil <- name_of(term) do
      MapSet.put(value, {:name, name})
    else
      _ -> value
    end
  end

  defp emit_signal(facts, at, ictx, mfa) do
    case Map.fetch(@signals, mfa) do
      {:ok, {signal, reg}} ->
        sources(
          facts,
          at,
          :process_signal_source,
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
        Resolve.resolve_atom(at.fun.instrs, at.idx, {:x, 1}),
        val(ictx, {:x, 0})
      )

  defp emit_register(facts, at, ictx, {:erlang, :register, 2}),
    do:
      register_row(
        facts,
        at,
        Resolve.resolve_atom(at.fun.instrs, at.idx, {:x, 0}),
        val(ictx, {:x, 1})
      )

  defp emit_register(facts, at, ictx, {:global, :register_name, arity}) when arity in [2, 3] do
    name =
      case Resolve.resolve_register(at.fun.instrs, at.idx, {:x, 0}) do
        {:ok, name} -> name_of({:global, name}) || "dynamic"
        _ -> "dynamic"
      end

    register_row(facts, at, name, val(ictx, {:x, 1}))
  end

  # A process registers itself under a key of a Registry.
  defp emit_register(facts, at, _ictx, {Registry, :register, 3}) do
    instrs = at.fun.instrs

    name =
      with {:ok, registry} <- Resolve.resolve_register(instrs, at.idx, {:x, 0}),
           {:ok, key} <- Resolve.resolve_register(instrs, at.idx, {:x, 1}) do
        name_of({:via, Registry, {registry, key}}) || "dynamic"
      else
        _ -> "dynamic"
      end

    register_row(facts, at, name, MapSet.new([:self]))
  end

  defp emit_register(facts, _at, _ictx, _mfa), do: facts

  defp register_row(facts, _at, "dynamic", _value), do: facts

  defp register_row(facts, at, name, value),
    do:
      sources(
        facts,
        at,
        :process_register_source,
        [site(at.fun, at.idx), at.fun.func_id, name],
        value
      )

  defp emit_send(facts, at, ictx, {mod, :send, arity})
       when (mod == :erlang and arity in [2, 3]) or (mod == Process and arity == 3),
       do: send_row(facts, at, ictx)

  defp emit_send(facts, _at, _ictx, _mfa), do: facts

  # A send is keyed on its site for the finding about what it sends, and is
  # also an "info" call: to a server, the message lands in handle_info/2.
  defp send_row(facts, at, ictx) do
    id = site(at.fun, at.idx)
    message = message(at.fun.instrs, at.idx)

    facts =
      if envelope?(at.fun.instrs, at.idx), do: add_fact(facts, :send_envelope, [id]), else: facts

    facts
    |> sources(at, :process_send_source, [id, at.fun.func_id, message], destination(at, ictx))
    |> call_rows(at, ictx, "info")
  end

  # The message as a receive pattern would read it: a literal atom, a
  # tuple's literal atom tag, or unknown.
  defp message(instrs, idx) do
    case Resolve.resolve_register(instrs, idx, {:x, 1}) do
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

  # The gen behaviours' envelopes, by tag and size: process_send_source's message
  # spells a tuple by its tag alone, and `{:system, :reload}` is a
  # message, not :sys's `{:system, from, request}` (review 2, item 33).
  @envelopes %{:"$gen_call" => 3, :"$gen_cast" => 2, :system => 3}

  defp envelope?(instrs, idx) do
    case Resolve.resolve_register(instrs, idx, {:x, 1}) do
      {:ok, tuple} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        Map.get(@envelopes, elem(tuple, 0)) == tuple_size(tuple)

      _ ->
        false
    end
  end

  # A tail call returns whatever the call returns.
  defp emit_tail(facts, at, ictx, _site) do
    if elem(elem(at.fun.code, at.idx), 0) in @tail_ops do
      value = Map.get(ictx.state.outs, {at.idx, "x0"}, MapSet.new())
      sources(facts, at, :value_return, [at.fun.func_id], value)
    else
      facts
    end
  end

  # The loads an evaluation made, and what its unknown-key reads could not
  # see (`load/5`), escaped at this instruction.
  defp emit_loads(facts, at, r) do
    r.loads
    |> Enum.reduce(facts, fn {id, sel, token}, inner ->
      sources(inner, at, :value_load, [at.fun.func_id, id, sel], MapSet.new([token]))
    end)
    |> sources(
      at,
      :value_escape,
      [site(at.fun, at.idx), at.fun.func_id],
      Map.get(r, :unseen, MapSet.new())
    )
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

  # A `result` source names its call site; `value_result` says what it calls.
  defp emit_results(facts, ctx, value) do
    Enum.reduce(value, facts, fn
      {:result, idx}, acc ->
        add_fact(acc, :value_result, [
          site(ctx.fun, idx),
          ctx.fun.func_id,
          answering(ctx.fun, idx)
        ])

      _token, acc ->
        acc
    end)
  end

  # The function whose answer a call's result is: the callee, or the fun
  # of the program a library call runs on a list's elements.
  defp answering(fun, idx) do
    case Map.get(fun.library, idx) do
      %{runs: runs} when is_binary(runs) ->
        runs

      _ ->
        %{mfa: mfa} = Map.fetch!(fun.sites, idx)
        callee(mfa)
    end
  end

  defp convert(ctx, value) do
    value
    |> Enum.flat_map(fn
      {:proc, proc} ->
        [{"proc", proc}]

      {:table, table} ->
        [{"table", table}]

      {:param, k} ->
        [{"param", Integer.to_string(k)}]

      {:result, idx} ->
        [{"result", site(ctx.fun, idx)}]

      {:reply, idx} ->
        [{"reply", site(ctx.fun, idx)}]

      {:remote, idx} ->
        [{"remote", site(ctx.fun, idx)}]

      {:name, name} ->
        [{"name", name}]

      {:dict, key} ->
        [{"dict", key}]

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
  defp emit_row(facts, :value_arg, row), do: add_fact(facts, :value_arg, row)
  defp emit_row(facts, :value_return, row), do: add_fact(facts, :value_return, row)
  defp emit_row(facts, :process_call_source, row), do: add_fact(facts, :process_call_source, row)

  defp emit_row(facts, :process_message_source, row),
    do: add_fact(facts, :process_message_source, row)

  defp emit_row(facts, :process_register_source, row),
    do: add_fact(facts, :process_register_source, row)

  defp emit_row(facts, :process_send_source, row), do: add_fact(facts, :process_send_source, row)

  defp emit_row(facts, :process_signal_source, row),
    do: add_fact(facts, :process_signal_source, row)

  defp emit_row(facts, :value_field, row), do: add_fact(facts, :value_field, row)
  defp emit_row(facts, :value_base, row), do: add_fact(facts, :value_base, row)
  defp emit_row(facts, :value_load, row), do: add_fact(facts, :value_load, row)

  defp emit_row(facts, :process_probe_source, row),
    do: add_fact(facts, :process_probe_source, row)

  defp emit_row(facts, :table_use, row), do: add_fact(facts, :table_use, row)
  defp emit_row(facts, :dict_put, row), do: add_fact(facts, :dict_put, row)
  defp emit_row(facts, :task_op_source, row), do: add_fact(facts, :task_op_source, row)
  defp emit_row(facts, :value_escape, row), do: add_fact(facts, :value_escape, row)

  # ── Names ────────────────────────────────────────────────────────────

  defp site(fun, idx), do: InstrId.mint(fun.func_id, idx)

  # A term a call builds inside its result has a second name at the site.
  defp obj_id(fun, {idx, n}) when is_integer(n), do: site(fun, idx) <> "/" <> Integer.to_string(n)

  defp obj_id(fun, {idx, {:lib, path}}),
    do: site(fun, idx) <> "/" <> Enum.map_join(path, ".", &path_step/1)

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

  defp path_step({kind, id}), do: "#{kind}(#{id})"
  defp path_step(n), do: to_string(n)

  defp table(fun, idx), do: "table " <> site(fun, idx)
end
