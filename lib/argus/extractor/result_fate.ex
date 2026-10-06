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
  of the function handed to a call that discards what the fun answers
  (`Enum.each/2`), or maps it into a list that is then dropped. An
  exported function's callers are outside the module, one with no use in
  the module is called from elsewhere, and a fun kept or handed anywhere
  else may keep what it answers: each keeps the answer, the direction
  that keeps a "lost" fact honest.

  `Argus.Extractors.Monitor` asks it of monitor refs.
  """

  import Argus.Extractor.Helpers,
    only: [cfg: 2, cfg: 3, match_local_call: 1, match_remote_call: 1, register: 1]

  alias Argus.Cfg.Walk
  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.InstrId

  @typedoc "A call: its function, that function's instructions, and its index."
  @type ctx :: %{
          required(:func_id) => String.t(),
          required(:instrs) => [tuple()],
          required(:idx) => non_neg_integer(),
          optional(atom()) => term()
        }

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
          reorder?(instr) -> follow.(writer, {:x, 0})
          Instr.call?(instr) -> writer
          true -> nil
        end
    end)
  end

  @reorders [
    {:lists, :reverse, 1},
    {Enum, :reverse, 1},
    {Enum, :sort, 1},
    {Enum, :uniq, 1},
    {Enum, :to_list, 1}
  ]

  defp reorder?(instr) do
    case match_remote_call(instr) do
      {:ok, mod, fun, arity} -> {mod, fun, arity} in @reorders
      :none -> false
    end
  end

  # A monitor made as a tail call, or whose ref every return answers,
  # hands its ref to whoever called the function: `Enum.map(pids, &Process.monitor(&1))` compiles to a closure
  # whose last instruction is the monitor, and the list Enum.map returns
  # holds every ref (exq's WorkerDrainer awaits them all). Nothing
  # follows the call in its own function, so the walk below would find
  # the ref read nowhere; the question is the callers' instead.
  @doc "Whether the answer of the call at `ctx.idx` is lost (above)."
  @spec lost?(map(), ctx()) :: boolean()
  def lost?(module_data, ctx) do
    if Instr.tail_call?(Enum.at(ctx.instrs, ctx.idx)) or returns_ref?(ctx.instrs, ctx.idx),
      do: returned_ref_lost?(module_data, ctx.func_id, []),
      else: ref_dropped?(cfg(module_data, ctx), ctx.instrs, ctx.idx + 1)
  end

  # Every return of the function answers the ref the monitor at `idx`
  # took, as a tail call to it would: `ref = Process.monitor(pid); send(pid,
  # :stop); ...; ref`. Whether it is lost is the callers' question.
  defp returns_ref?(instrs, idx) do
    returns = for {:return, at} <- Enum.with_index(instrs), do: at
    returns != [] and Enum.all?(returns, &(origin_call(instrs, &1, {:x, 0}) == idx))
  end

  # Whether every use the module shows of the function `func_id`, which
  # returns a monitor's ref, loses it: a call that drops its result (or
  # a tail call whose own caller does, a few hops up), or a closure or
  # local capture of it handed to a call that discards what the fun
  # returns (`lists:foreach/2`, `Enum.each/2`). An exported function's
  # callers are outside the module, one with no use in it is called from
  # elsewhere, and a fun kept or handed anywhere else may keep what it
  # returns: each keeps the ref, the direction that keeps the fact honest.
  @max_hops 4

  defp returned_ref_lost?(module_data, func_id, seen) do
    with {:ok, %{func: name, arity: arity}} <- InstrId.parse_func(func_id),
         false <- func_id in seen or length(seen) >= @max_hops,
         false <- {String.to_atom(name), arity} in module_data.exports,
         [_ | _] = uses <- uses_of(module_data, String.to_atom(name), arity) do
      seen = [func_id | seen]
      # One use that loses it is one monitor per call nothing can
      # release, whatever the others keep (review 2, item 26: 206ec0cd
      # asked every use).
      Enum.any?(uses, &use_loses_ref?(module_data, &1, seen))
    else
      _ -> false
    end
  end

  # Each place in the module that calls the function or makes a fun of
  # it: `{:call, caller_id, caller, index}` or `{:fun, caller, index}`.
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

  defp use_loses_ref?(module_data, {:call, ctx, {caller, arity}}, seen) do
    if Instr.tail_call?(Enum.at(ctx.instrs, ctx.idx)),
      do: returned_ref_lost?(module_data, ctx.func_id, seen),
      else: ref_dropped?(cfg(module_data, caller, arity), ctx.instrs, ctx.idx + 1)
  end

  defp use_loses_ref?(module_data, {:fun, ctx, {caller, arity}}, _seen) do
    case handed_to_discarding_call?(ctx.instrs, ctx.idx) do
      true -> true
      # `Enum.map(pids, &Process.monitor/1)` whose list of refs is dropped.
      {:mapped, at} -> ref_dropped?(cfg(module_data, caller, arity), ctx.instrs, at + 1)
      false -> false
    end
  end

  # Calls that run a fun and return what it returns, collected: the refs
  # are lost when the list is.
  @mapping_calls %{{:lists, :map, 2} => 0, {Enum, :map, 2} => 1}

  # Calls that run a fun for its effects and throw away what it returns,
  # with the argument position the fun is handed in.
  @discarding_calls %{
    {:lists, :foreach, 2} => 0,
    {:maps, :foreach, 2} => 0,
    {Enum, :each, 2} => 1
  }

  # Follows the fun `make_fun3` at `idx` writes through the registers to
  # the call it is handed to, and asks whether that call is one that
  # discards what the fun returns, handed the fun where it takes one. A
  # call it is not handed to is stepped over (the fun waits in a `y`
  # register while ejabberd's init reads the table it will fold over).
  # Anything else — a branch, a store, another call taking it — keeps it.
  defp handed_to_discarding_call?(instrs, idx) do
    {:make_fun3, _target, _index, _uniq, dst, _env} = Enum.at(instrs, idx)

    instrs
    |> Enum.drop(idx + 1)
    |> Enum.reduce_while([register(dst)], fn instr, holding ->
      cond do
        holding == [] ->
          {:halt, false}

        (verdict = handed_verdict(instr, holding)) != nil ->
          {:halt, verdict}

        (Instr.call?(instr) or Instr.tail_call?(instr)) and
            Enum.any?(Instr.uses(instr), &(&1 in holding)) ->
          {:halt, false}

        Instr.tail_call?(instr) or not Instr.falls_through?(instr) or Instr.targets(instr) != [] ->
          {:halt, false}

        true ->
          {:cont, Instr.carry(instr, holding)}
      end
    end)
    |> case do
      {:mapped, instr} -> {:mapped, mapped_index(instrs, idx, instr)}
      other -> other == true
    end
  end

  # A call the fun is handed to that discards what it returns (true), or
  # maps it into a list ({:mapped, instr}); nil for any other instruction.
  defp handed_verdict(instr, holding) do
    cond do
      (Instr.call?(instr) or Instr.tail_call?(instr)) and discarding_call?(instr, holding) -> true
      Instr.call?(instr) and mapping_call?(instr, holding) -> {:mapped, instr}
      true -> nil
    end
  end

  defp mapped_index(instrs, idx, instr) do
    instrs
    |> Enum.with_index()
    |> Enum.drop(idx + 1)
    |> Enum.find_value(fn {i, at} -> if i == instr, do: at end)
  end

  defp mapping_call?(instr, holding) do
    with {:ok, mod, name, arity} <- match_remote_call(instr),
         {:ok, pos} <- Map.fetch(@mapping_calls, {mod, name, arity}) do
      {:x, pos} in holding
    else
      _ -> false
    end
  end

  defp discarding_call?(instr, holding) do
    with {:ok, mod, name, arity} <- match_remote_call(instr),
         {:ok, pos} <- Map.fetch(@discarding_calls, {mod, name, arity}) do
      {:x, pos} in holding
    else
      _ -> false
    end
  end

  @x0 {:x, 0}

  # Walks forward from the call along every path. Each instruction either
  # reads {x,0} (the ref is kept, and the answer is no), writes it without
  # reading (this path is done, the ref is gone on it), touches it not at
  # all (keep looking), or is something with x0 in a position whose
  # meaning is unknown — and that is "kept": a fact claiming a ref is gone
  # must be sure. Dropped when no path reaches a read. Without a graph
  # (a module whose facts could not be decoded) the ref counts as kept.
  defp ref_dropped?(nil, _instrs, _start), do: false

  defp ref_dropped?(fun, instrs, start) do
    result =
      Walk.explore(fun, instrs, [start],
        on_instr: fn
          {:func_info, _, _, _}, _idx ->
            :prune

          instr, _idx ->
            case classify(instr) do
              :reads -> {:halt, :kept}
              :unknown -> {:halt, :kept}
              :writes -> :prune
              :neutral -> :continue
            end
        end
      )

    match?({:done, _}, result)
  end

  # What an instruction does with the ref in {x,0}. `test_heap` with no
  # live registers and `deallocate` say what the compiler knows of x0's
  # liveness: dead at the first, about to be returned at the second.
  defp classify({:test_heap, _words, 0}), do: :writes
  defp classify({:deallocate, _}), do: :reads

  defp classify(instr) do
    cond do
      not Instr.known?(instr) -> :unknown
      @x0 in Instr.uses(instr) -> :reads
      Instr.defines?(instr, @x0) -> :writes
      true -> :neutral
    end
  end
end
