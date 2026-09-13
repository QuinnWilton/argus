defmodule Argus.Extractors.Reply do
  @moduledoc """
  What an OTP callback returns, and whether it kept the means to reply.

  `handle_call/3` may answer immediately with `{:reply, value, state}`, or
  defer by returning `{:noreply, state}` and calling `GenServer.reply/2`
  later. Deferring is a promise, and the only thing that can discharge it is
  the `from` term the callback was handed — an opaque `{pid, tag}` that
  exists nowhere else.

  So a `handle_call/3` clause that returns `{:noreply, _}` while never
  reading its `from` parameter has made a promise it cannot keep, no matter
  what the rest of the system does. The caller blocks for the full
  `GenServer.call/3` timeout and then exits.

  ## Approach

  Both halves are visible in bytecode without dataflow.

  A callback's return shape is a tuple built into `{x, 0}` immediately
  before `return`, and its tag is a literal atom:

      {:put_tuple2, {:x, 0}, {:list, [atom: :noreply, x: 2]}}
      :return

  And `from` is argument 1, so it arrives in `{x, 1}`. Reading it is either
  a mention of that register or a call of arity two or more, because calls
  take their arguments positionally: a body that passes `from` straight
  through, as `publish(payload, from, state)` does, compiles to no move at
  all and mentions the register nowhere.

  Which sites drop `from` is then a reachability question — walk the
  control-flow graph from the entry, refuse to pass through any instruction
  that reads `from`, and see which `{:noreply, _}` sites remain. Per site,
  not per function: `handle_call/3` compiles every clause into one function,
  and asking function-wide lets a clause that defers correctly vouch for one
  that does not.

  Both directions of imprecision are toward silence. A tail call hides the
  return shape, so no tag is recorded; a write to `{x, 1}` counts as a read,
  so a clobbered register looks retained; and any two-argument call counts,
  so a callback that merely passes its arguments along is never reported.

  ## Emitted facts

  - `callback_return(id, func, callback, tag)` — a literal return tag
  - `callback_stop_reason(id, func, reason)` — the reason of a
    `{:stop, reason, ...}` return when it is a literal atom or a
    `{:shutdown, term}` literal
  - `callback_timeout(id, func, callback, timeout_ms)` — the literal integer
    timeout of a `{:ok, state, ms}`, `{:noreply, state, ms}` or
    `{:reply, reply, state, ms}` return
  - `callback_drops_from(id, func)` — a `{:noreply, _}` site some execution
    reaches without ever having read `from`

  A whole return folded into one literal — `{:ok, %{}, 0}` with a
  constant state compiles to a single `move` of the tuple into `{x, 0}` —
  is read the same way as a tuple built in place.
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg
  alias Argus.Cfg.Walk
  alias Argus.Extractor.Dispatch
  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [add_fact: 3, cfg: 3, return_shapes: 1]

  # Callbacks whose return shape is a contract worth recording. Bounded on
  # purpose: return tags are only meaningful where a behaviour ascribes
  # meaning to them, and emitting one per function in the program would be
  # a large relation that no rule could interpret.
  @callbacks %{
    {:handle_call, 3} => "handle_call",
    {:handle_cast, 2} => "handle_cast",
    {:handle_info, 2} => "handle_info",
    {:handle_continue, 2} => "handle_continue",
    {:init, 1} => "init",
    {:handle_event, 4} => "handle_event"
  }

  # `from` is handle_call/3's second argument, so it arrives in {x, 1}.
  @from_register {:x, 1}

  @impl true
  def relations,
    do: [
      :callback_drops_from,
      :callback_return,
      :callback_stop_reason,
      :callback_timeout
    ]

  @impl true
  def extract(%{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, acc ->
      case Map.fetch(@callbacks, {name, arity}) do
        {:ok, callback} ->
          func_id = InstrId.func_id(mod, name, arity)

          acc
          |> emit_returns(func_id, callback, instrs)
          |> emit_retains_from(func_id, name, arity, instrs, cfg(module_data, name, arity))

        :error ->
          acc
      end
    end)
  end

  defp emit_returns(facts, func_id, callback, instrs) do
    instrs
    |> return_shapes()
    |> Enum.reduce(facts, fn
      {idx, [{:atom, tag} | rest]}, acc ->
        id = InstrId.mint(func_id, idx)

        acc
        |> add_fact(:callback_return, [id, func_id, callback, inspect(tag)])
        |> emit_stop_reason(id, func_id, tag, rest)
        |> emit_timeout(id, func_id, callback, tag, rest)

      _other, acc ->
        acc
    end)
  end

  # {:stop, reason, state} and {:stop, reason, reply, state}: the reason
  # is the second element either way. Only a literal reason is recorded —
  # a computed one says nothing about whether the stop is normal.
  defp emit_stop_reason(facts, id, func_id, :stop, [reason | _rest]) do
    case stop_reason(reason) do
      nil -> facts
      reason -> add_fact(facts, :callback_stop_reason, [id, func_id, reason])
    end
  end

  defp emit_stop_reason(facts, _id, _func_id, _tag, _rest), do: facts

  defp stop_reason({:atom, reason}), do: inspect(reason)
  defp stop_reason({:literal, {:shutdown, _term}}), do: ":shutdown"
  defp stop_reason(_element), do: nil

  # A trailing integer is a timeout: `{:ok, state, ms}` and
  # `{:noreply, state, ms}` carry it third, `{:reply, reply, state, ms}`
  # fourth. `:hibernate` and `{:continue, _}` sit in the same slot and
  # are not integers.
  defp emit_timeout(facts, id, func_id, callback, tag, [_state, {:integer, ms}])
       when tag in [:ok, :noreply] do
    add_fact(facts, :callback_timeout, [id, func_id, callback, to_string(ms)])
  end

  defp emit_timeout(facts, id, func_id, callback, :reply, [_reply, _state, {:integer, ms}]) do
    add_fact(facts, :callback_timeout, [id, func_id, callback, to_string(ms)])
  end

  defp emit_timeout(facts, _id, _func_id, _callback, _tag, _rest), do: facts

  # Per return site, not per function. Whether a callback keeps `from` is a
  # property of the clause that defers, and `handle_call/3` compiles every
  # clause into one function: asking the question function-wide lets a
  # sibling clause that defers correctly vouch for one that does not. That
  # is not a rounding error, it is the difference between finding the bug
  # and not — the interesting case is precisely a multi-clause callback
  # where one clause forgets.
  #
  # So: walk the intra-function control-flow graph from the entry, refusing
  # to pass through any instruction that reads `from`, and ask which
  # {:noreply, _} sites are still reachable. Those are the ones some
  # execution arrives at having never touched the term.
  #
  # Instruction-level rather than block-level, because the two interleave.
  # Elixir inlines the first clause into the entry block, so a block there
  # holds both the dispatch test for the *other* clauses and a body that
  # stores `from`; at block granularity that store poisons the entry and
  # nothing downstream is ever reported.
  defp emit_retains_from(facts, func_id, :handle_call, 3, instrs, %Cfg.Function{} = fun) do
    reachable = reachable_without_from(fun, instrs)

    instrs
    |> return_shapes()
    |> Enum.reduce(facts, fn
      {idx, [{:atom, :noreply} | _]}, acc ->
        if MapSet.member?(reachable, idx),
          do: add_fact(acc, :callback_drops_from, [InstrId.mint(func_id, idx), func_id]),
          else: acc

      _other, acc ->
        acc
    end)
  end

  defp emit_retains_from(facts, _func_id, _name, _arity, _instrs, _fun), do: facts

  # Forward walk from the entry across instructions that do not read
  # `from`. A reading instruction is reached but not passed: everything
  # downstream of it has seen the term.
  defp reachable_without_from(fun, instrs) do
    {:done, visited} =
      Walk.explore(fun, instrs, [Dispatch.entry_index(instrs)],
        on_instr: fn instr, _idx -> if references_from?(instr), do: :prune, else: :continue end
      )

    visited
  end

  # A register can be read without ever appearing as an operand. Calls take
  # their arguments positionally in {x,0}..{x,arity-1}, so a handle_call/3
  # body doing
  #
  #     publish(Payload, From, State)
  #
  # compiles to a bare `{:call, 3, ...}` with no moves at all: the arguments
  # are already in the right registers. Searching for {x,1} finds nothing
  # and the callback looks as though it dropped `from`, when it passed it
  # on. amqp_rpc_client is exactly this shape, and treating an argument
  # order that happens to match as evidence of a bug is how a static
  # analysis earns its reputation.
  #
  # So any call of arity two or more counts as a read, as does `send`, whose
  # operands are implicit in {x,0} and {x,1}.
  defp references_from?(instr) do
    reads_from_positionally?(instr) or mentions?(instr, @from_register)
  end

  defp reads_from_positionally?({:call, arity, _}), do: arity >= 2
  defp reads_from_positionally?({:call_only, arity, _}), do: arity >= 2
  defp reads_from_positionally?({:call_last, arity, _, _}), do: arity >= 2
  defp reads_from_positionally?({:call_ext, arity, _}), do: arity >= 2
  defp reads_from_positionally?({:call_ext_only, arity, _}), do: arity >= 2
  defp reads_from_positionally?({:call_ext_last, arity, _, _}), do: arity >= 2
  defp reads_from_positionally?({:call_fun, arity}), do: arity >= 2
  defp reads_from_positionally?({:call_fun2, _, arity, _}), do: arity >= 2
  defp reads_from_positionally?({:apply, arity}), do: arity >= 2
  defp reads_from_positionally?({:apply_last, arity, _}), do: arity >= 2
  defp reads_from_positionally?(:send), do: true
  defp reads_from_positionally?(_instr), do: false

  defp mentions?(@from_register, @from_register), do: true
  defp mentions?(term, reg) when is_tuple(term), do: term |> Tuple.to_list() |> mentions?(reg)
  defp mentions?(term, reg) when is_list(term), do: Enum.any?(term, &mentions?(&1, reg))
  defp mentions?(_term, _reg), do: false
end
