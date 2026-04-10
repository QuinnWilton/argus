defmodule Argus.Extractors.OTP do
  @moduledoc """
  OTP pattern extractor.

  Detects OTP behaviour implementations and GenServer.call/cast targets
  from module attributes and bytecode patterns.

  ## Emitted facts

  - `implements_behaviour(mod, behaviour)` — module implements a behaviour
  - `sync_call(caller_func, callee_mod)` — GenServer.call target detected
  - `sync_call_timeout(caller_func, callee_mod, timeout_ms)` — timeout value at call site
  - `sync_call_via(caller_func, registry, key)` — sync call to a `{:via, _, _}` target
  - `async_cast(caller_func, callee_mod)` — GenServer.cast target detected
  - `process_link(from_mod, to_mod)` — Process.link / :erlang.link call
  - `delayed_message(sender_func, target, message)` — Process.send_after, :timer.send_after,
    :timer.apply_after — implicit handle_info sources
  - `deferred_reply(handler_func, from_arg)` — `GenServer.reply/2` call site
  - `init_continues_to(mod, tag)` — module's init/1 returns `{:continue, tag}`
  - `handle_continue_clause(mod, tag, func_id)` — handle_continue/2 clause matching `tag`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      get_behaviours: 1,
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
    |> extract_delayed_messages(mod, functions)
    |> extract_deferred_replies(mod, functions)
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
    case Argus.Extractor.Helpers.find_function(functions, :init, 1) do
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
    |> Argus.Extractor.Helpers.scan_return_tuples()
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
  defp clause_tags(instrs) do
    Enum.flat_map(instrs, fn
      {:test, :is_eq_exact, _, [{:x, 0}, {:atom, tag}]} when is_atom(tag) ->
        [inspect(tag)]

      {:select_val, {:x, 0}, _fail, {:list, pairs}} ->
        pairs
        |> Enum.chunk_every(2)
        |> Enum.flat_map(fn
          [{:atom, tag}, _label] when is_atom(tag) -> [inspect(tag)]
          _ -> []
        end)

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp extract_deferred_replies(facts, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_deferred_reply(acc, ctx, mfa)
    end)
  end

  defp handle_deferred_reply(facts, ctx, {GenServer, :reply, 2}) do
    from_arg = resolve_from_arg(ctx.instrs, ctx.idx)

    facts
    |> track_dynamic(from_arg, ctx, :deferred_reply_from, :deferred_reply)
    |> add_fact(:deferred_reply, [ctx.func_id, from_arg])
  end

  defp handle_deferred_reply(facts, ctx, {:gen_server, :reply, 2}) do
    from_arg = resolve_from_arg(ctx.instrs, ctx.idx)

    facts
    |> track_dynamic(from_arg, ctx, :deferred_reply_from, :deferred_reply)
    |> add_fact(:deferred_reply, [ctx.func_id, from_arg])
  end

  defp handle_deferred_reply(facts, _ctx, _mfa), do: facts

  # GenServer.reply(from, response) — first arg is the from reference.
  # Most commonly it's a parameter (handle_call's `from`) stored in state
  # and read back later. We record arg:N when it's a parameter, "dynamic"
  # otherwise.
  defp resolve_from_arg(instrs, idx) do
    case Argus.Extractor.Helpers.arg_position(instrs, idx, {:x, 0}) do
      {:ok, n} -> "arg:#{n}"
      :no -> "dynamic"
    end
  end

  defp extract_delayed_messages(facts, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_delayed(acc, ctx, mfa)
    end)
  end

  # Process.send_after(dest, message, time) — dest in x0, message in x1.
  defp handle_delayed(facts, ctx, {Process, :send_after, arity}) when arity in [3, 4] do
    emit_delayed(facts, ctx, {:x, 0}, {:x, 1})
  end

  # :erlang.send_after(time, dest, message) — dest in x1, message in x2.
  defp handle_delayed(facts, ctx, {:erlang, :send_after, arity}) when arity in [3, 4] do
    emit_delayed(facts, ctx, {:x, 1}, {:x, 2})
  end

  # :timer.send_after(time, message) and (time, dest, message). Two arities.
  defp handle_delayed(facts, ctx, {:timer, :send_after, 2}) do
    # send_after(time, message) — message in x1, target is self()
    emit_delayed_to_self(facts, ctx, {:x, 1})
  end

  defp handle_delayed(facts, ctx, {:timer, :send_after, 3}) do
    # send_after(time, dest, message) — dest in x1, message in x2
    emit_delayed(facts, ctx, {:x, 1}, {:x, 2})
  end

  # :timer.apply_after(time, mod, func, args) — fires apply, not send.
  # Modeled with target = "<mod>:<func>/<arity>" and message = "apply".
  defp handle_delayed(facts, ctx, {:timer, :apply_after, 4}) do
    target = Argus.Extractor.Helpers.resolve_atom(ctx.instrs, ctx.idx, {:x, 1})

    facts
    |> track_dynamic(target, ctx, :delayed_target, :delayed_message)
    |> add_fact(:delayed_message, [ctx.func_id, target, "apply"])
  end

  defp handle_delayed(facts, _ctx, _mfa), do: facts

  defp emit_delayed(facts, ctx, target_reg, msg_reg) do
    target = resolve_target(ctx.instrs, ctx.idx, target_reg)
    message = resolve_message(ctx.instrs, ctx.idx, msg_reg)

    facts
    |> track_dynamic(target, ctx, :delayed_target, :delayed_message)
    |> track_dynamic(message, ctx, :delayed_message_pattern, :delayed_message)
    |> add_fact(:delayed_message, [ctx.func_id, target, message])
  end

  defp emit_delayed_to_self(facts, ctx, msg_reg) do
    message = resolve_message(ctx.instrs, ctx.idx, msg_reg)

    facts
    |> track_dynamic(message, ctx, :delayed_message_pattern, :delayed_message)
    |> add_fact(:delayed_message, [ctx.func_id, "self", message])
  end

  # The target of a send_after can be self(), a registered name, a pid, or
  # a function parameter. We try to recover the most useful classification.
  defp resolve_target(instrs, idx, register) do
    case Argus.Extractor.Helpers.resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) ->
        # Whether it's a process name (:my_proc) or a module (MyMod).
        inspect(atom)

      _ ->
        case Argus.Extractor.Helpers.last_call_writer(instrs, idx, register) do
          {:ok, {:erlang, :self, 0}} ->
            "self"

          _ ->
            case Argus.Extractor.Helpers.arg_position(instrs, idx, register) do
              {:ok, n} -> "arg:#{n}"
              :no -> "dynamic"
            end
        end
    end
  end

  # The message body is typically a literal atom (`:tick`) or a tagged
  # tuple. We capture the leading atom for handler matching.
  defp resolve_message(instrs, idx, register) do
    case Argus.Extractor.Helpers.resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) ->
        inspect(atom)

      {:ok, tuple} when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        case elem(tuple, 0) do
          a when is_atom(a) -> inspect(a)
          _ -> "dynamic"
        end

      _ ->
        "dynamic"
    end
  end

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
    {Agent, :get, 2},
    {Agent, :update, 2},
    {Agent, :get_and_update, 2}
  ]

  # Explicit-timeout sync calls (timeout in x2).
  @explicit_timeout_sync [
    {GenServer, :call, 3},
    {:gen_server, :call, 3},
    {Agent, :get, 3},
    {Agent, :update, 3},
    {Agent, :get_and_update, 3}
  ]

  # Async cast calls.
  @async_cast_calls [
    {GenServer, :cast, 2},
    {:gen_server, :cast, 2}
  ]

  defp handle_genserver_call(facts, ctx, mfa) when mfa in @default_timeout_sync do
    {callee, facts} = resolve_target_with_via(facts, ctx)

    facts
    |> add_fact(:sync_call, [ctx.func_id, callee])
    |> add_fact(:sync_call_timeout, [ctx.func_id, callee, "5000"])
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

  defp handle_genserver_call(facts, _ctx, _mfa), do: facts

  # Resolve the call target's first argument (x0 — the GenServer reference)
  # to a callee tag, and emit a sync_call_via fact when the value is a
  # `{:via, _, {registry_instance, key}}` tuple.
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
    case Argus.Extractor.Helpers.resolve_register(ctx.instrs, ctx.idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) ->
        {inspect(atom), facts}

      {:ok, {:via, _via_mod, {reg_instance, key}}} when is_atom(reg_instance) ->
        registry = inspect(reg_instance)
        callee = "via:#{registry}"
        facts = add_fact(facts, :sync_call_via, [ctx.func_id, registry, inspect(key)])
        {callee, facts}

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
