defmodule Argus.Extractors.Reply do
  @moduledoc """
  OTP callback returns and whether a deferred reply keeps `from`.

  A `handle_call/3` returning `{:noreply, state}` must retain or use its
  `from` argument so someone can reply later. This extractor records a dropped
  `from` when a path returns that tuple without referencing the argument.
  Checks are per return construction, so a correct clause cannot hide a broken
  sibling. References after tuple construction count too.

  Return tuples come from `Argus.Extractor.Shapes`, which follows copies and
  control-flow joins. The `from` check walks paths that do not reference `x1`,
  including implicit reads by calls and sends. Writes to `x1` also stop the
  walk conservatively. Tail calls have no visible tuple shape.

  ## Emitted facts

  - `callback_return(id, func, callback, tag)` — a literal return tag
  - `callback_stop_reason(id, func, reason)` — a literal atom or
    `{:shutdown, term}` reason in a `{:stop, reason, ...}` return
  - `callback_timeout(id, func, callback, timeout_ms)` — an integer timeout in
    an `:ok`, `:noreply`, or `:reply` return
  - `callback_drops_from(id, func)` — a returned `:noreply` tuple reached on a
    path that never references `from`
  """

  @behaviour Argus.Extractor

  alias Argus.Cfg
  alias Argus.Cfg.Walk
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [cfg: 3]
  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Shapes, only: [return_shapes: 1]

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
  def candidate?(key), do: is_map_key(@callbacks, key)

  @impl true
  def extract(%{module: mod, functions: functions} = module_data) do
    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, acc ->
      case Map.fetch(@callbacks, {name, arity}) do
        {:ok, callback} ->
          func_id = InstrId.func_id(mod, name, arity)
          shapes = return_shapes(instrs)

          acc
          |> emit_returns(func_id, callback, shapes)
          |> emit_dropped_from(func_id, callback, instrs, cfg(module_data, name, arity), shapes)

        :error ->
          acc
      end
    end)
  end

  defp emit_returns(facts, func_id, callback, shapes) do
    Enum.reduce(shapes, facts, fn
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

  # Find candidate constructions without a prior reference to `from`, then
  # check that the tuple can reach a return without a later reference either.
  # Instruction-level walks keep sibling clauses in the same block separate.
  defp emit_dropped_from(facts, func_id, "handle_call", instrs, %Cfg.Function{} = fun, shapes) do
    reachable = reachable_without_from(fun, instrs)

    Enum.reduce(shapes, facts, fn
      {idx, [{:atom, :noreply} | _]}, acc ->
        if MapSet.member?(reachable, idx) and returns_without_from?(fun, instrs, idx),
          do: add_fact(acc, :callback_drops_from, [InstrId.mint(func_id, idx), func_id]),
          else: acc

      _other, acc ->
        acc
    end)
  end

  defp emit_dropped_from(facts, _func_id, _callback, _instrs, _fun, _shapes), do: facts

  # `from` can still be used after the result tuple is built. Follow that
  # tuple, so another branch returning a different value cannot vouch for it.
  defp returns_without_from?(fun, instrs, idx) do
    instr = Enum.at(instrs, idx)

    reg =
      case instr do
        {:put_tuple2, dst, _elements} -> Instr.register(dst)
        {:move, _literal, dst} -> Instr.register(dst)
        {:put_tuple, _size, dst} -> Instr.register(dst)
      end

    not references_from?(instr) and
      Walk.carries_to_return?(fun, instrs, idx + 1, reg, &references_from?/1)
  end

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

  # Calls and sends read implicit argument registers. Explicit mentions,
  # including overwrites, conservatively count as retaining `from` too.
  defp references_from?(instr) do
    @from_register in Instr.uses(instr) or
      Terms.mentions?(instr, &(&1 == @from_register))
  end
end
