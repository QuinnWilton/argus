defmodule Argus.Extractors.OTP do
  @moduledoc """
  OTP pattern extractor.

  Detects OTP behaviour implementations and GenServer.call/cast targets
  from module attributes and bytecode patterns.

  ## Emitted facts

  - `implements_behaviour(mod, behaviour)` — module implements a behaviour
  - `sync_call(caller_func, callee_mod)` — GenServer.call target detected
  - `sync_call_timeout(caller_func, callee_mod, timeout_ms)` — timeout value at call site
  - `sup_call(id, func, api, op, target)` — a synchronous management call into a
    supervisor process (`Supervisor.start_child/2`, `DynamicSupervisor.terminate_child/2`,
    `Task.Supervisor.async_nolink/2`, ...); `target` is the supervisor argument
  - `async_cast(caller_func, callee_mod)` — GenServer.cast target detected
  - `process_link(from_mod, to_mod)` — Process.link / :erlang.link call
  - `init_continues_to(mod, tag)` — module's init/1 returns `{:continue, tag}`
  - `handle_continue_clause(mod, tag, func_id)` — handle_continue/2 clause matching `tag`
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Helpers
  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      get_behaviours: 1,
      match_remote_call: 1,
      resolve_callee: 1,
      resolve_register: 3,
      scan_remote_calls: 4,
      track_dynamic: 5,
      track_imprecision: 4
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    functions = module_data.functions

    %{}
    |> extract_behaviours(mod_str, module_data.attributes)
    |> extract_genserver_calls(mod, functions)
    |> extract_link_calls(mod_str, mod, functions)
    |> extract_continue_facts(mod, mod_str, functions)
  end

  # Two facts:
  #   - init_continues_to(mod, tag) when init/1 returns {:ok, _, {:continue, tag}}
  #   - handle_continue_clause(mod, tag, func_id) for each handle_continue/2 clause
  defp extract_continue_facts(facts, mod, mod_str, functions) do
    facts
    |> extract_init_continues(mod, mod_str, functions)
    |> extract_handle_continue_clauses(mod, mod_str, functions)
  end

  defp extract_init_continues(facts, _mod, mod_str, functions) do
    case Helpers.find_function(functions, :init, 1) do
      nil ->
        facts

      instrs ->
        # Two shapes are common in real BEAM bytecode:
        #   1. The whole return is a literal: `move {literal, {:ok, _, {:continue, tag}}}, x0`.
        #      The compiler folds the entire term when the state is also a literal.
        #   2. The return is built at runtime via `put_tuple2`. The third element
        #      is either a literal `{:continue, tag}` or another `put_tuple2`.
        (tags_from_literals(instrs) ++ tags_from_put_tuples(instrs))
        |> Enum.uniq()
        |> Enum.reduce(facts, fn tag, acc ->
          add_fact(acc, :init_continues_to, [mod_str, tag])
        end)
    end
  end

  defp tags_from_literals(instrs) do
    Enum.flat_map(instrs, fn
      {:move, {:literal, {:ok, _state, {:continue, tag}}}, _dst} when is_atom(tag) ->
        [inspect(tag)]

      {:move, {:literal, {:noreply, _state, {:continue, tag}}}, _dst} when is_atom(tag) ->
        [inspect(tag)]

      _ ->
        []
    end)
  end

  defp tags_from_put_tuples(instrs) do
    instrs
    |> Helpers.scan_return_tuples()
    |> Enum.flat_map(fn {_idx, elements} ->
      case continue_tag(elements) do
        nil -> []
        tag -> [tag]
      end
    end)
  end

  # Look for {:ok, _state, {:continue, tag}} or {:noreply, _state, {:continue, tag}}
  # shapes in a put_tuple2 element list.
  defp continue_tag([{:atom, :ok}, _state, third]), do: extract_continue_from_element(third)

  defp continue_tag([{:atom, :noreply}, _state, third]),
    do: extract_continue_from_element(third)

  defp continue_tag(_), do: nil

  defp extract_continue_from_element({:literal, {:continue, tag}}) when is_atom(tag),
    do: inspect(tag)

  defp extract_continue_from_element(_), do: nil

  # For handle_continue clauses, identify them by name + arity.
  defp extract_handle_continue_clauses(facts, _mod, mod_str, functions) do
    Enum.reduce(functions, facts, fn
      {:function, :handle_continue, 2, _entry, instrs}, acc ->
        func_id = "#{mod_str}:handle_continue/2"

        # The clause head dispatches on the first argument (the tag). We
        # can't easily separate clauses without more analysis, but we can
        # detect tag literals from the test instructions at the top.
        tags = clause_tags(instrs)

        if tags == [] do
          add_fact(acc, :handle_continue_clause, [mod_str, "dynamic", func_id])
        else
          Enum.reduce(tags, acc, fn tag, inner ->
            add_fact(inner, :handle_continue_clause, [mod_str, tag, func_id])
          end)
        end

      _, acc ->
        acc
    end)
  end

  # Find tag literals matched by `is_eq_exact` or `select_val` against x0
  # at the top of handle_continue/2.
  # Only the dispatch prologue, not the whole function.
  #
  # The tag arrives in {x,0}, but {x,0} is also the BEAM's first scratch
  # register, so once a clause body starts it holds whatever that body is
  # working on. Scanning the entire function therefore collected every atom
  # any clause happened to compare against — `:ok`, `nil` and `false` were
  # recorded as handle_continue tags across the corpus, roughly half the
  # rows in the relation.
  #
  # It was quiet because a spurious tag matches nothing downstream and
  # produces silence rather than an error, and because `deferred_startup_
  # deadlock`, the only consumer, reports zero on these projects either way.
  #
  # Stopping at the first write to {x,0} is exact: up to that point the
  # register still holds the tag, and after it never does. Calls count as
  # writes, since they return into {x,0}.
  defp clause_tags(instrs) do
    instrs
    |> Enum.reduce_while([], fn instr, acc ->
      if writes_x0?(instr), do: {:halt, acc}, else: {:cont, acc ++ dispatch_tags(instr)}
    end)
    |> Enum.uniq()
  end

  defp dispatch_tags({:test, :is_eq_exact, _, [{:x, 0}, {:atom, tag}]}) when is_atom(tag),
    do: [inspect(tag)]

  defp dispatch_tags({:select_val, {:x, 0}, _fail, {:list, pairs}}) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [{:atom, tag}, _label] when is_atom(tag) -> [inspect(tag)]
      _ -> []
    end)
  end

  defp dispatch_tags(_instr), do: []

  defp writes_x0?({:move, _src, {:x, 0}}), do: true
  defp writes_x0?({:get_tuple_element, _src, _idx, {:x, 0}}), do: true
  defp writes_x0?({:put_tuple2, {:x, 0}, _}), do: true
  defp writes_x0?({:put_tuple, _size, {:x, 0}}), do: true
  defp writes_x0?({:put_map_assoc, _f, _src, {:x, 0}, _live, _list}), do: true
  defp writes_x0?({:bif, _name, _f, _args, {:x, 0}}), do: true
  defp writes_x0?({:gc_bif, _name, _f, _live, _args, {:x, 0}}), do: true
  defp writes_x0?(instr), do: match_remote_call(instr) != :none or local_call?(instr)

  defp local_call?({:call, _a, _mfa}), do: true
  defp local_call?({:call_only, _a, _mfa}), do: true
  defp local_call?({:call_last, _a, _mfa, _d}), do: true
  defp local_call?(_instr), do: false

  defp extract_behaviours(facts, mod_str, attrs) do
    attrs
    |> get_behaviours()
    |> Enum.reduce(facts, fn behaviour, acc ->
      add_fact(acc, :implements_behaviour, [mod_str, inspect(behaviour)])
    end)
  end

  defp extract_genserver_calls(facts, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_genserver_call(acc, ctx, mfa)
    end)
  end

  # Default-timeout sync calls (5000ms): {Module, function, arity} → match.
  @default_timeout_sync [
    {GenServer, :call, 2},
    {:gen_server, :call, 2},
    {GenStage, :call, 2},
    {Agent, :get, 2},
    {Agent, :update, 2},
    {Agent, :get_and_update, 2}
  ]

  # Sync calls whose default timeout is :infinity, not 5000ms. A
  # gen_statem client that omits the timeout waits forever.
  @infinity_default_sync [
    {:gen_statem, :call, 2},
    {GenStateMachine, :call, 2}
  ]

  # Explicit-timeout sync calls (timeout in x2).
  @explicit_timeout_sync [
    {GenServer, :call, 3},
    {:gen_server, :call, 3},
    {:gen_statem, :call, 3},
    {GenStateMachine, :call, 3},
    {GenStage, :call, 3},
    {Agent, :get, 3},
    {Agent, :update, 3},
    {Agent, :get_and_update, 3}
  ]

  # Async cast calls.
  @async_cast_calls [
    {GenServer, :cast, 2},
    {:gen_server, :cast, 2},
    {:gen_statem, :cast, 2},
    {GenStateMachine, :cast, 2},
    {GenStage, :cast, 2}
  ]

  # Synchronous management calls into a supervisor process. Every one of
  # these is a GenServer.call under the hood — start_child waits for the
  # child's init/1 to return, terminate_child waits for the child's whole
  # shutdown — but none names a GenServer module, so they were invisible
  # to every analysis reasoning about who blocks on whom. The supervisor
  # argument is always {x,0}.
  @sup_calls [
    {Supervisor, :start_child, 2},
    {Supervisor, :terminate_child, 2},
    {Supervisor, :restart_child, 2},
    {Supervisor, :delete_child, 2},
    {Supervisor, :which_children, 1},
    {Supervisor, :count_children, 1},
    {Supervisor, :stop, 1},
    {Supervisor, :stop, 2},
    {Supervisor, :stop, 3},
    {DynamicSupervisor, :start_child, 2},
    {DynamicSupervisor, :terminate_child, 2},
    {DynamicSupervisor, :which_children, 1},
    {DynamicSupervisor, :count_children, 1},
    {DynamicSupervisor, :stop, 1},
    {DynamicSupervisor, :stop, 2},
    {DynamicSupervisor, :stop, 3},
    {Task.Supervisor, :start_child, 2},
    {Task.Supervisor, :start_child, 3},
    {Task.Supervisor, :async, 2},
    {Task.Supervisor, :async, 3},
    {Task.Supervisor, :async, 4},
    {Task.Supervisor, :async_nolink, 2},
    {Task.Supervisor, :async_nolink, 3},
    {Task.Supervisor, :async_nolink, 4},
    {Task.Supervisor, :terminate_child, 2},
    {Task.Supervisor, :children, 1},
    {PartitionSupervisor, :which_children, 1},
    {PartitionSupervisor, :count_children, 1}
  ]

  defp handle_genserver_call(facts, ctx, mfa) when mfa in @default_timeout_sync do
    {callee, facts} = resolve_target_with_via(facts, ctx)

    facts
    |> add_fact(:sync_call, [ctx.func_id, callee])
    |> add_fact(:sync_call_timeout, [ctx.func_id, callee, "5000"])
  end

  defp handle_genserver_call(facts, ctx, mfa) when mfa in @infinity_default_sync do
    {callee, facts} = resolve_target_with_via(facts, ctx)

    facts
    |> add_fact(:sync_call, [ctx.func_id, callee])
    |> add_fact(:sync_call_timeout, [ctx.func_id, callee, "-1"])
  end

  defp handle_genserver_call(facts, ctx, mfa) when mfa in @explicit_timeout_sync do
    {callee, facts} = resolve_target_with_via(facts, ctx)
    timeout = resolve_timeout(ctx.instrs, ctx.idx, {:x, 2})

    facts
    |> track_timeout_imprecision(timeout, ctx)
    |> add_fact(:sync_call, [ctx.func_id, callee])
    |> add_fact(:sync_call_timeout, [ctx.func_id, callee, timeout])
  end

  defp handle_genserver_call(facts, ctx, mfa) when mfa in @async_cast_calls do
    {callee, facts} = resolve_target_with_via(facts, ctx)
    add_fact(facts, :async_cast, [ctx.func_id, callee])
  end

  # GenServer.multi_call/2,3,4 — synchronous multi-node call, infinity default.
  defp handle_genserver_call(facts, ctx, {GenServer, :multi_call, arity})
       when arity in [2, 3, 4] do
    {callee, facts} = resolve_target_with_via(facts, ctx)

    facts
    |> add_fact(:sync_call, [ctx.func_id, callee])
    |> add_fact(:sync_call_timeout, [ctx.func_id, callee, "-1"])
  end

  defp handle_genserver_call(facts, ctx, {api, op, _arity} = mfa) when mfa in @sup_calls do
    {target, facts} = resolve_supervisor_target(facts, ctx)

    add_fact(facts, :sup_call, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      inspect(api),
      to_string(op),
      target
    ])
  end

  defp handle_genserver_call(facts, _ctx, _mfa), do: facts

  # The supervisor argument of a management call, in the same vocabulary
  # as sync_call's callee: a module atom, "via:Registry" for a via tuple,
  # or "dynamic". Kept apart from resolve_target_with_via/2 so that a
  # supervisor named through a registry does not also mint a
  # sync_call_via row, which resolved_calls.dl reads as evidence of a
  # GenServer.call.
  defp resolve_supervisor_target(facts, ctx) do
    case Helpers.resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) and atom != :dynamic ->
        {inspect(atom), facts}

      {:ok, {:via, _via_mod, {reg_instance, _key}}}
      when is_atom(reg_instance) and reg_instance != :dynamic ->
        {"via:#{inspect(reg_instance)}", facts}

      _ ->
        {"dynamic", track_imprecision(facts, ctx, :supervisor_target, :sup_call)}
    end
  end

  # Resolve the call target's first argument (x0 — the GenServer reference)
  # to a callee tag.
  #
  # The shape `{:via, Registry, {MyApp.Registry, :worker_a}}` decomposes as:
  #   - the second element is the via-module (Registry behaviour) — ignored here
  #   - the third element is `{registry_instance, key}` where registry_instance
  #     is the named registry process (e.g. MyApp.Registry) that owns the key
  #
  # Returns `{callee_tag, updated_facts}` where `callee_tag` is one of:
  # - `"Module"` (inspected literal atom)
  # - `"via:RegistryInstance"` (when the target is a via tuple)
  # - `"dynamic"` (everything else, including function parameters)
  defp resolve_target_with_via(facts, ctx) do
    case Helpers.resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) ->
        {inspect(atom), facts}

      # reg_instance != :dynamic: a partially resolved via tuple carries the
      # placeholder atom in the registry slot — inspecting it would forge a
      # "via::dynamic" callee that the dynamic filters don't recognize.
      {:ok, {:via, _via_mod, {reg_instance, _key}}}
      when is_atom(reg_instance) and reg_instance != :dynamic ->
        {"via:#{inspect(reg_instance)}", facts}

      _ ->
        facts = track_imprecision(facts, ctx, :genserver_callee, :sync_call)
        {"dynamic", facts}
    end
  end

  # The "0" in sync_call_timeout is a sentinel for "we couldn't resolve
  # the timeout argument" — record it as imprecision so the coverage
  # report knows about it.
  defp track_timeout_imprecision(facts, "0", ctx) do
    track_imprecision(facts, ctx, :sync_call_timeout, :sync_call_timeout)
  end

  defp track_timeout_imprecision(facts, _other, _ctx), do: facts

  defp extract_link_calls(facts, mod_str, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_link(acc, mod_str, ctx, mfa)
    end)
  end

  defp handle_link(facts, mod_str, ctx, {Process, :link, 1}) do
    callee = resolve_callee(ctx)

    facts
    |> track_dynamic(callee, ctx, :process_link_target, :process_link)
    |> add_fact(:process_link, [mod_str, callee])
  end

  defp handle_link(facts, mod_str, ctx, {:erlang, :link, 1}) do
    callee = resolve_callee(ctx)

    facts
    |> track_dynamic(callee, ctx, :process_link_target, :process_link)
    |> add_fact(:process_link, [mod_str, callee])
  end

  defp handle_link(facts, _mod_str, _ctx, _mfa), do: facts

  # Resolve a timeout argument to its string representation for facts.
  # Positive integer → milliseconds, :infinity → "-1", anything else → "0" (dynamic).
  defp resolve_timeout(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, n} when is_integer(n) and n > 0 -> to_string(n)
      {:ok, :infinity} -> "-1"
      _ -> "0"
    end
  end
end
