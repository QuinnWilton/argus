defmodule Argus.Extractors.Monitor do
  @moduledoc """
  Monitor and demonitor call sites.

  A monitor is a promise the runtime keeps: once `Process.monitor/1`
  returns, a `{:DOWN, ref, :process, object, reason}` message **will** arrive
  unless the monitor is cancelled. Nothing in the calling code says so, and
  the message can arrive arbitrarily later — after a `receive` gave up
  waiting, after the state machine moved on, after the reason stopped
  meaning anything.

  Two consequences, and both are structural.

  `Process.demonitor(ref)` cancels, but a `{:DOWN, ...}` already in the
  mailbox stays there; only `Process.demonitor(ref, [:flush])` removes it.
  So the flush option is recorded separately — it is the difference between
  cancelling a future message and cancelling a message that has already been
  sent.

  And a process that monitors is a process that receives `:DOWN`. That makes
  "will this specific message arrive?" answerable for once, where in general
  it is not: the analysis need not guess what lands in a mailbox if the code
  asked for it.

  ## Emitted facts

  - `monitor_call(id, func, target)` — a monitor is established
  - `demonitor_call(id, func, flush)` — `flush` is `"flush"` or `"no_flush"`
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, match_remote_call: 1, resolve_atom: 3, scan_functions: 4]

  @impl true
  def extract(%{module: mod, functions: functions}) do
    scan_functions(mod, functions, %{}, fn facts, ctx, instr ->
      case match_remote_call(instr) do
        {:ok, m, f, a} -> handle(facts, ctx, {m, f, a})
        :none -> facts
      end
    end)
  end

  defp handle(facts, ctx, {Process, :monitor, 1}), do: monitor(facts, ctx)
  defp handle(facts, ctx, {:erlang, :monitor, 2}), do: monitor(facts, ctx)

  defp handle(facts, ctx, {Process, :demonitor, arity}) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, ctx, {:erlang, :demonitor, arity}) when arity in [1, 2],
    do: demonitor(facts, ctx, arity)

  defp handle(facts, _ctx, _mfa), do: facts

  defp monitor(facts, ctx) do
    add_fact(facts, :monitor_call, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      resolve_atom(ctx.instrs, ctx.idx, {:x, 0})
    ])
  end

  # demonitor/1 cannot flush — the option list is the only way — so arity is
  # a sound lower bound on the answer. For arity 2 the list is read when it
  # is a literal, and anything else is "no_flush", which is the direction
  # that keeps a finding rather than silently discharging one.
  defp demonitor(facts, ctx, 1) do
    add_fact(facts, :demonitor_call, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      "no_flush"
    ])
  end

  defp demonitor(facts, ctx, 2) do
    add_fact(facts, :demonitor_call, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      flush_option(ctx.instrs, ctx.idx)
    ])
  end

  defp flush_option(instrs, idx) do
    instrs
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.find_value("no_flush", fn
      {:move, {:literal, opts}, {:x, 1}} when is_list(opts) ->
        if :flush in opts, do: "flush", else: "no_flush"

      {:move, _src, {:x, 1}} ->
        "no_flush"

      _ ->
        false
    end)
  end
end
