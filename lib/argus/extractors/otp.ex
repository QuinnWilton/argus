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
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      get_behaviours: 1,
      resolve_callee: 1,
      resolve_register: 3,
      scan_remote_calls: 4
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
        {"dynamic", facts}
    end
  end

  defp extract_link_calls(facts, mod_str, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_link(acc, mod_str, ctx, mfa)
    end)
  end

  defp handle_link(facts, mod_str, ctx, {Process, :link, 1}) do
    add_fact(facts, :process_link, [mod_str, resolve_callee(ctx)])
  end

  defp handle_link(facts, mod_str, ctx, {:erlang, :link, 1}) do
    add_fact(facts, :process_link, [mod_str, resolve_callee(ctx)])
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
