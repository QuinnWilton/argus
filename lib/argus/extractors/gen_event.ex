defmodule Argus.Extractors.GenEvent do
  @moduledoc """
  gen_event extractor.

  `:gen_event` is one of the four core OTP behaviours alongside
  `gen_server`, `gen_statem`, and `supervisor`. Argus had no coverage
  for it before this extractor — every `:gen_event.sync_notify/2` (a
  blocking call to every handler in turn) was invisible to deadlock
  detection, and `:gen_event.notify/2` (the async fan-out) was missing
  from the message-flow story.

  This extractor reuses the same `sync_call` and `async_cast` relations
  the OTP extractor uses for GenServer, so existing analyses
  (`call_cycle`, `process_bottleneck`, `sync_call_in_init`) automatically
  pick up gen_event-based deadlocks and hot-spots without needing
  dedicated rules.

  ## Emitted facts

  - `sync_call(caller_func, callee_mod)` — `:gen_event.sync_notify/2`
  - `async_cast(caller_func, callee_mod)` — `:gen_event.notify/2`
    `:gen_event.add_handler/3` registrations
  - `implements_behaviour(mod, ":gen_event")` — modules that declare the
    behaviour (handlers and managers)
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      get_behaviours: 1,
      resolve_callee: 1,
      scan_remote_calls: 4
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    functions = module_data.functions

    %{}
    |> extract_behaviour(mod_str, module_data.attributes)
    |> extract_calls(mod, functions)
  end

  defp extract_behaviour(facts, mod_str, attrs) do
    if :gen_event in get_behaviours(attrs) do
      add_fact(facts, :implements_behaviour, [mod_str, ":gen_event"])
    else
      facts
    end
  end

  defp extract_calls(facts, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_call(acc, ctx, mfa)
    end)
  end

  # :gen_event.sync_notify(Manager, Event) — synchronous fan-out to every
  # handler. Reuses sync_call so call_cycle / process_bottleneck pick it up.
  defp handle_call(facts, ctx, {:gen_event, :sync_notify, 2}) do
    callee = resolve_callee(ctx)
    add_fact(facts, :sync_call, [ctx.func_id, callee])
  end

  # :gen_event.notify(Manager, Event) — async fan-out.
  defp handle_call(facts, ctx, {:gen_event, :notify, 2}) do
    callee = resolve_callee(ctx)
    add_fact(facts, :async_cast, [ctx.func_id, callee])
  end

  # :gen_event.call(Manager, Handler, Request) and /4 with timeout.
  defp handle_call(facts, ctx, {:gen_event, :call, arity}) when arity in [3, 4] do
    callee = resolve_callee(ctx)
    add_fact(facts, :sync_call, [ctx.func_id, callee])
  end

  defp handle_call(facts, _ctx, _mfa), do: facts
end
