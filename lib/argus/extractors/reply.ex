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
  - `callback_drops_from(id, func)` — a `{:noreply, _}` site some execution
    reaches without ever having read `from`
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [add_fact: 3]

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
  def extract(%{module: mod, functions: functions}) do
    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, acc ->
      case Map.fetch(@callbacks, {name, arity}) do
        {:ok, callback} ->
          func_id = InstrId.func_id(mod, name, arity)

          acc
          |> emit_returns(func_id, callback, instrs)
          |> emit_retains_from(func_id, name, arity, instrs)

        :error ->
          acc
      end
    end)
  end

  defp emit_returns(facts, func_id, callback, instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      case return_tag(instr, instrs, idx) do
        {:ok, tag} ->
          add_fact(acc, :callback_return, [InstrId.mint(func_id, idx), func_id, callback, tag])

        :none ->
          acc
      end
    end)
  end

  # A tuple built into {x, 0} and immediately returned. `put_tuple2` is what
  # OTP 24+ emits; the older `put_tuple`/`put` sequence is handled too, since
  # analysing dependencies built by an older compiler is routine.
  defp return_tag({:put_tuple2, {:x, 0}, {:list, [{:atom, tag} | _]}}, instrs, idx) do
    if returns_next?(instrs, idx + 1), do: {:ok, inspect(tag)}, else: :none
  end

  defp return_tag({:put_tuple, _size, {:x, 0}}, instrs, idx) do
    case Enum.at(instrs, idx + 1) do
      {:put, {:atom, tag}} ->
        if returns_next?(instrs, skip_puts(instrs, idx + 1)), do: {:ok, inspect(tag)}, else: :none

      _ ->
        :none
    end
  end

  defp return_tag(_instr, _instrs, _idx), do: :none

  # Line markers and frame teardown may sit between the tuple and the
  # return. Anything else means the tuple is not what comes back.
  defp returns_next?(instrs, idx) do
    case Enum.at(instrs, idx) do
      :return -> true
      {:line, _} -> returns_next?(instrs, idx + 1)
      {:deallocate, _} -> returns_next?(instrs, idx + 1)
      {:trim, _, _} -> returns_next?(instrs, idx + 1)
      _ -> false
    end
  end

  defp skip_puts(instrs, idx) do
    case Enum.at(instrs, idx) do
      {:put, _} -> skip_puts(instrs, idx + 1)
      _ -> idx
    end
  end

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
  defp emit_retains_from(facts, func_id, :handle_call, 3, instrs) do
    reachable = reachable_without_from(instrs)

    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {instr, idx}, acc ->
      with {:ok, ":noreply"} <- return_tag(instr, instrs, idx),
           true <- Map.has_key?(reachable, idx) do
        add_fact(acc, :callback_drops_from, [InstrId.mint(func_id, idx), func_id])
      else
        _ -> acc
      end
    end)
  end

  defp emit_retains_from(facts, _func_id, _name, _arity, _instrs), do: facts

  # Forward walk from the entry instruction across instructions that do not
  # read `from`. A reading instruction is reached but not passed: everything
  # downstream of it has seen the term.
  @spec reachable_without_from([tuple()]) :: %{non_neg_integer() => true}
  defp reachable_without_from(instrs) do
    indexed = Enum.with_index(instrs)
    by_idx = Map.new(indexed, fn {instr, idx} -> {idx, instr} end)
    labels = Map.new(for {{:label, l}, idx} <- indexed, do: {l, idx})

    walk([entry_index(instrs)], by_idx, labels, length(instrs), %{})
  end

  # Execution does NOT begin at the first instruction. BEAM emits the
  # function's error label first — `{:label, L}, {:func_info, M, F, A}` —
  # and entry is what follows it. Starting at index zero reaches a
  # `func_info` that raises, walks nowhere, and reports nothing.
  defp entry_index(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> 0
      idx -> idx + 1
    end
  end

  @spec walk([non_neg_integer()], map(), map(), non_neg_integer(), %{non_neg_integer() => true}) ::
          %{non_neg_integer() => true}
  defp walk([], _by_idx, _labels, _len, seen), do: seen

  defp walk([idx | rest], by_idx, labels, len, seen) do
    cond do
      idx >= len or Map.has_key?(seen, idx) ->
        walk(rest, by_idx, labels, len, seen)

      references_from?(Map.fetch!(by_idx, idx)) ->
        walk(rest, by_idx, labels, len, Map.put(seen, idx, true))

      true ->
        instr = Map.fetch!(by_idx, idx)
        next = successors(instr, idx, labels)
        walk(next ++ rest, by_idx, labels, len, Map.put(seen, idx, true))
    end
  end

  defp successors(instr, idx, labels) do
    targets =
      instr
      |> branch_targets()
      |> Enum.flat_map(fn l -> List.wrap(Map.get(labels, l)) end)

    if terminator?(instr), do: Enum.uniq(targets), else: Enum.uniq([idx + 1 | targets])
  end

  defp branch_targets(instr), do: collect_f(instr, [])

  defp collect_f({:f, l}, acc) when is_integer(l) and l > 0, do: [l | acc]

  defp collect_f(term, acc) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.reduce(acc, &collect_f/2)

  defp collect_f(term, acc) when is_list(term), do: Enum.reduce(term, acc, &collect_f/2)
  defp collect_f(_term, acc), do: acc

  # Control leaves without falling through. Tail calls count, since their
  # return value is the function's.
  defp terminator?(:return), do: true
  defp terminator?({:jump, _}), do: true
  defp terminator?({:select_val, _, _, _}), do: true
  defp terminator?({:select_tuple_arity, _, _, _}), do: true
  defp terminator?({:call_only, _, _}), do: true
  defp terminator?({:call_last, _, _, _}), do: true
  defp terminator?({:call_ext_only, _, _}), do: true
  defp terminator?({:call_ext_last, _, _, _}), do: true
  defp terminator?({:apply_last, _, _}), do: true
  defp terminator?({:wait, _}), do: true
  defp terminator?({:func_info, _, _, _}), do: true
  defp terminator?(:if_end), do: true
  defp terminator?({:case_end, _}), do: true
  defp terminator?({:badmatch, _}), do: true
  defp terminator?(_instr), do: false

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
