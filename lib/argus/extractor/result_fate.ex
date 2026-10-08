defmodule Argus.Extractor.ResultFate do
  @moduledoc """
  Whether what a call answers is lost: nothing reads it, here or in any
  caller it is handed back to.

  A call's answer arrives in `{x, 0}`. It is dropped when, on every path
  from the call, the next thing to happen to that register is a write
  that does not read it. A call in tail position (or one whose answer
  every return hands back) passes the question to the function's
  callers in the module: lost when one use loses it — a call that drops
  it, a tail call whose own caller does (a few hops up), or a fun made
  of the function handed to a library call that drops what the fun
  answers (`Enum.each/2`), or keeps it in a list that is then dropped
  (`Enum.map/2`). An exported function's callers are outside the module,
  one with no use in the module is called from elsewhere, and a fun
  kept or handed anywhere else may keep what it answers: each keeps the
  answer, the direction that keeps a "lost" fact honest.

  The library calls that run a fun, and whether they keep what it
  answers, are `Argus.Extractors.TermFlow.Library`'s.

  Monitor refs (`Argus.Extractors.Monitor`) and start results
  (`Argus.Extractors.ErrorHandling`) ask it.
  """

  import Argus.Extractor.Helpers, only: [cfg: 2, match_local_call: 1, match_remote_call: 1]
  import Argus.Instr, only: [register: 1]

  alias Argus.Cfg.Block
  alias Argus.Cfg.Function, as: Graph
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.TermFlow.Library
  alias Argus.Instr
  alias Argus.InstrId

  @typedoc "A call: its function, that function's instructions, and its index."
  @type ctx :: %{
          required(:func_id) => String.t(),
          required(:instrs) => [tuple()],
          required(:idx) => non_neg_integer(),
          optional(atom()) => term()
        }

  # Library calls running a fun, by whether they hand back what it
  # answers: {position the fun is handed in, kept?}.
  @runs Library.runs()

  @max_hops 4

  @x0 {:x, 0}

  @doc "Whether the answer of the call at `ctx.idx` is lost (above)."
  @spec lost?(map(), ctx()) :: boolean()
  def lost?(module_data, ctx), do: lost?(module_data, ctx, [])

  defp lost?(module_data, ctx, seen) do
    fate =
      if Instr.tail_call?(Enum.at(ctx.instrs, ctx.idx)),
        do: :returned,
        else: fate(cfg(module_data, ctx), ctx.instrs, ctx.idx + 1)

    case fate do
      :kept -> false
      :dropped -> true
      :returned -> returned_lost?(module_data, ctx.func_id, seen)
    end
  end

  @doc """
  The call whose result `reg` holds at `at`, directly or as an element
  of it, on every path; nil when none or several. A library call that
  hands back its list's elements in another order (the reverse a
  comprehension ends with) is followed to the call that made the list.
  """
  @spec origin_call([tuple()], non_neg_integer(), term()) :: non_neg_integer() | nil
  def origin_call(instrs, at, reg) do
    Resolve.trace(instrs, at, register(reg), nil, fn
      {:param, _position}, _follow ->
        nil

      {writer, {:get_tuple_element, src, _index, _dst}}, follow ->
        follow.(writer, src)

      {writer, instr}, follow ->
        cond do
          0 in carried(instr) -> follow.(writer, {:x, 0})
          Instr.call?(instr) -> writer
          true -> nil
        end
    end)
  end

  # The library calls handing back (part of) an argument in what they
  # answer: `%{mfa => [position]}` (`TermFlow.Library`).
  @carried for {mfa, _model} <- Library.models(),
               args = Library.carried_args(mfa),
               args != [],
               into: %{},
               do: {mfa, args}

  defp carried(instr) do
    case match_remote_call(instr) do
      {:ok, mod, fun, arity} -> Map.get(@carried, {mod, fun, arity}, [])
      :none -> []
    end
  end

  defp returned_lost?(module_data, func_id, seen) do
    with {:ok, %{func: name, arity: arity}} <- InstrId.parse_func(func_id),
         false <- func_id in seen or length(seen) >= @max_hops,
         false <- {String.to_atom(name), arity} in module_data.exports,
         [_ | _] = uses <- uses_of(module_data, String.to_atom(name), arity) do
      seen = [func_id | seen]
      # One use that loses it is one answer per call nothing reads,
      # whatever the others keep.
      Enum.any?(uses, &use_loses?(module_data, &1, seen))
    else
      _ -> false
    end
  end

  # Each place in the module that calls the function or makes a fun of
  # it: `{:call | :fun, ctx, {caller, arity}}`.
  defp uses_of(%{module: mod, functions: functions}, name, arity) do
    for {:function, caller, caller_arity, _entry, instrs} <- functions,
        {instr, idx} <- Enum.with_index(instrs),
        use = use_at(instr, mod, name, arity),
        use != nil do
      {use, %{func_id: InstrId.func_id(mod, caller, caller_arity), instrs: instrs, idx: idx},
       {caller, caller_arity}}
    end
  end

  defp use_at(instr, mod, name, arity) do
    case {match_local_call(instr), instr} do
      {{:ok, ^mod, ^name, ^arity}, _} -> :call
      {_, {:make_fun3, {^mod, ^name, ^arity}, _, _, _, _}} -> :fun
      _ -> nil
    end
  end

  defp use_loses?(module_data, {:call, ctx, _caller}, seen), do: lost?(module_data, ctx, seen)

  defp use_loses?(module_data, {:fun, ctx, _caller}, seen) do
    case handed_to_run(ctx.instrs, ctx.idx) do
      :drops -> true
      # `Enum.map(pids, &Process.monitor/1)` whose list is lost in turn.
      {:keeps, at} -> lost?(module_data, %{ctx | idx: at}, seen)
      nil -> false
    end
  end

  # Follows the fun `make_fun3` at `idx` writes through the registers to
  # the call it is handed to: a library call running it that drops what
  # it answers (:drops), or keeps it in its own answer ({:keeps, index}
  # of that call). A call it is not handed to is stepped over (the fun
  # waits in a `y` register while ejabberd's init reads the table it will
  # fold over). Anything else — a branch, a store, another call taking
  # it — keeps it (nil).
  defp handed_to_run(instrs, idx) do
    {:make_fun3, _target, _index, _uniq, dst, _env} = Enum.at(instrs, idx)

    instrs
    |> Enum.with_index()
    |> Enum.drop(idx + 1)
    |> Enum.reduce_while([register(dst)], fn {instr, at}, holding ->
      cond do
        holding == [] ->
          {:halt, nil}

        (verdict = run_verdict(instr, at, holding)) != nil ->
          {:halt, verdict}

        (Instr.call?(instr) or Instr.tail_call?(instr)) and
            Enum.any?(Instr.uses(instr), &(&1 in holding)) ->
          {:halt, nil}

        Instr.tail_call?(instr) or not Instr.falls_through?(instr) or Instr.targets(instr) != [] ->
          {:halt, nil}

        true ->
          {:cont, Instr.carry(instr, holding)}
      end
    end)
    |> case do
      verdict when verdict == :drops or is_tuple(verdict) -> verdict
      _ -> nil
    end
  end

  # A library call the fun is handed to, where it takes one: :drops when
  # it drops what the fun answers, {:keeps, at} when its own answer holds
  # it.
  defp run_verdict(instr, at, holding) do
    with true <- Instr.call?(instr) or Instr.tail_call?(instr),
         {:ok, mod, name, arity} <- match_remote_call(instr),
         {:ok, {pos, kept?}} <- Map.fetch(@runs, {mod, name, arity}),
         true <- {:x, pos} in holding do
      if kept?, do: {:keeps, at}, else: :drops
    else
      _ -> nil
    end
  end

  # Follows the answer forward from `start` along every path, by the
  # registers holding it (`Instr.carry/2`: moves, swaps, trims; a call
  # clobbers every x register). An instruction reading a register that
  # holds it keeps it — a test, a store, a call handed it — except a term
  # built of it (a list cell, a tuple, a map), which then holds it too,
  # and a library call handing back the argument it is in, whose answer
  # then holds it. A return of a register holding it hands it back; a path
  # on which no register holds it any more has dropped it. The fate:
  # :kept when any path keeps it, else :returned when any path hands it
  # back, else :dropped. Anything the walk cannot read keeps it — a fact
  # claiming an answer is lost must be sure — and without a graph (a
  # module whose facts could not be decoded) it is kept.
  defp fate(nil, _instrs, _start), do: :kept

  defp fate(fun, instrs, start) do
    state = %{fun: fun, instrs: List.to_tuple(instrs)}
    walk_fate([{start, @x0}], state, %{}, :dropped)
  end

  defp walk_fate([], _state, _visited, fate), do: fate

  defp walk_fate([{idx, reg} = point | rest], state, visited, fate) do
    if idx >= tuple_size(state.instrs) or Map.has_key?(visited, point) do
      walk_fate(rest, state, visited, fate)
    else
      visited = Map.put(visited, point, true)

      case step(elem(state.instrs, idx), reg) do
        :kept -> :kept
        :returned -> walk_fate(rest, state, visited, :returned)
        :gone -> walk_fate(rest, state, visited, fate)
        {:held, regs} -> walk_fate(next_points(state, idx, regs) ++ rest, state, visited, fate)
      end
    end
  end

  defp next_points(state, idx, regs), do: for(at <- next(state, idx), reg <- regs, do: {at, reg})

  # What one instruction does with the answer in `reg`.
  defp step(:return, @x0), do: :returned
  defp step(:return, _reg), do: :gone
  defp step({:func_info, _, _, _}, _reg), do: :gone

  defp step(instr, reg) do
    cond do
      not Instr.known?(instr) ->
        :kept

      reg not in Instr.uses(instr) ->
        untouched(instr, reg)

      builds_term?(instr) ->
        {:held, Enum.uniq(Instr.defs(instr) ++ Instr.carry(instr, [reg]))}

      (pos = arg_position(reg)) != nil and pos in carried(instr) ->
        handed_back(instr, reg)

      copies?(instr, reg) ->
        {:held, Instr.carry(instr, [reg])}

      true ->
        :kept
    end
  end

  # An instruction not reading the register: it stops holding the answer
  # when written or clobbered; a tail call ends the path, as a return of
  # something else does.
  defp untouched(instr, reg) do
    if Instr.tail_call?(instr), do: :gone, else: held_or_gone(Instr.carry(instr, [reg]))
  end

  # A library call handing back the argument holding the answer: its
  # answer (x0) holds it, and a register it does not clobber still does.
  defp handed_back(instr, reg) do
    if Instr.tail_call?(instr),
      do: :returned,
      else: held_or_gone(Enum.uniq([@x0 | Instr.carry(instr, [reg])]))
  end

  # A move, swap or trim copying the register elsewhere.
  defp copies?(instr, reg),
    do: Enum.any?(Instr.defs(instr), &(Instr.copy_source(instr, &1) == reg))

  defp held_or_gone([]), do: :gone
  defp held_or_gone(regs), do: {:held, regs}

  defp builds_term?(instr) do
    case instr do
      {:put_list, _, _, _} -> true
      {:put_tuple2, _, _} -> true
      {op, _, _, _, _, _} when op in [:put_map_assoc, :put_map_exact] -> true
      _ -> false
    end
  end

  defp arg_position({:x, n}), do: n
  defp arg_position(_reg), do: nil

  # Inside a block the next instruction follows; at the block's last
  # instruction its out-edges lead to their blocks' first instructions.
  defp next(state, idx) do
    case Graph.block_at(state.fun, idx) do
      %Block{range: {_first, last}} = block when last == idx ->
        for {to, _kind} <- block.succs,
            %Block{range: {first, _}} = Map.fetch!(state.fun.blocks, to),
            do: first

      _ ->
        [idx + 1]
    end
  end
end
