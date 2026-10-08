defmodule Argus.Extractors.ErrorHandling.RaiseSources do
  @moduledoc """
  The ways a function can raise: through an instruction of its own, or
  through a call whose callee raises.

  A linked task whose body cannot fail never takes its caller down, so
  a rule asking whether one can needs this per function and the call
  graph to chain it: the extractor names what each function's own code
  can raise through, and the rules decide the callees.

  An instruction raises unless it cannot (`Boundary.inert?/1`: moves,
  term construction, branches, guard BIFs with a fail label, total
  BIFs) or it is one of the operations below that answer for every
  operand: a return, a receive's instructions, a `wait_timeout` on a
  literal timeout, and a send (the instruction, or a call of
  `:erlang.send/2`) to anything but a name. A send to a pid never
  raises; one to a name nobody registers raises badarg, so a send to a
  destination that resolves to an atom or `{name, node}` raises. One
  that does not resolve is taken to be a pid's: a name held in a
  variable is the gap. A clause head that can fail, any test or select
  that falls to the function's `func_info`, raises FunctionClauseError.
  Anything else, including an instruction this list does not know,
  raises: the sound answer for a rule that suppresses on "cannot fail".

  A call raises through its callee (`Mod:fun/arity`), and a call
  through a fun or an apply through whatever runs (`dynamic`). Code
  inside a `try` whose handler takes every class whatever the reason
  (`CatchClauses`' totals: `:error`, `:exit` and `:throw`, or no class
  test), or an Erlang `catch`, raises nothing out of it; the handler's
  own code is the function's, and a re-raise there counts.
  """

  alias Argus.Cfg.Function
  alias Argus.Cfg.Walk
  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.ErrorHandling.Boundary
  alias Argus.Extractors.ErrorHandling.CatchClauses
  alias Argus.Instr
  alias Argus.InstrId

  # Instructions that answer for every operand, beyond Boundary's inert
  # ones: the return, the receive's, and the exception machinery that
  # moves a caught raise into registers.
  @answering [
    :return,
    :remove_message,
    :timeout,
    :loop_rec,
    :loop_rec_end,
    :wait,
    :recv_marker_bind,
    :recv_marker_clear,
    :recv_marker_reserve,
    :recv_marker_use,
    :func_info,
    :try,
    :try_case,
    :catch,
    :build_stacktrace
  ]

  @classes [:error, :exit, :throw]

  @doc """
  What the function whose instructions are `instrs` (and control-flow
  graph `fun`, `nil` when it could not be built) can raise through,
  sorted: `"self"`, `"dynamic"`, and the callees of the calls outside
  every try that takes all classes. Without a graph no try is taken to
  cover anything.
  """
  @spec sources([tuple() | atom()], Function.t() | nil) :: [String.t()]
  def sources(instrs, fun) do
    covered = covered(instrs, fun)

    body =
      instrs
      |> Enum.with_index()
      |> Enum.reject(fn {_instr, at} -> MapSet.member?(covered, at) end)
      |> Enum.flat_map(fn {instr, at} -> source(instr, instrs, at) end)

    head = if clause_can_fail?(instrs), do: ["self"], else: []
    (head ++ body) |> Enum.uniq() |> Enum.sort()
  end

  defp source(instr, instrs, at) do
    cond do
      # Elixir's send/2 is a call of :erlang.send/2, the send instruction's.
      Helpers.match_remote_call(instr) == {:ok, :erlang, :send, 2} ->
        if named_destination?(instrs, at), do: ["self"], else: []

      match?({:ok, _, _, _}, Helpers.match_remote_call(instr)) ->
        {:ok, m, f, a} = Helpers.match_remote_call(instr)
        [InstrId.func_id(m, f, a)]

      match?({:ok, _, _, _}, Helpers.match_local_call(instr)) ->
        {:ok, m, f, a} = Helpers.match_local_call(instr)
        [InstrId.func_id(m, f, a)]

      Instr.call?(instr) or Instr.tail_call?(instr) ->
        ["dynamic"]

      answers?(instr, instrs, at) ->
        []

      true ->
        ["self"]
    end
  end

  defp answers?(instr, instrs, at) do
    cond do
      instr in [:send, {:send}] -> not named_destination?(instrs, at)
      match?({:wait_timeout, _, _}, instr) -> literal_timeout?(elem(instr, 2))
      is_atom(instr) -> instr in @answering
      is_tuple(instr) and elem(instr, 0) in @answering -> true
      true -> Boundary.inert?(instr)
    end
  end

  # A send's destination in x0 resolved to a name: an atom, or `{name,
  # node}`. One that does not resolve is taken to be a pid.
  defp named_destination?(instrs, at) do
    case Resolve.resolve_register(instrs, at, {:x, 0}) do
      {:ok, name} when is_atom(name) -> true
      {:ok, {name, _node}} when is_atom(name) -> true
      _ -> false
    end
  end

  defp literal_timeout?({:integer, n}) when is_integer(n) and n >= 0, do: true
  defp literal_timeout?({:atom, :infinity}), do: true
  defp literal_timeout?(_operand), do: false

  # The label of the function's `func_info` is the target of a clause
  # head that does not match.
  defp clause_can_fail?(instrs) do
    case Dispatch.func_info_label(instrs) do
      nil -> false
      label -> Enum.any?(instrs, &(label in Instr.targets(&1)))
    end
  end

  # The instructions inside a try that takes every class, or an Erlang
  # catch: from the instruction after the try to its try_end (or the
  # handler's try_case), catch_end for a catch.
  defp covered(_instrs, nil), do: MapSet.new()

  defp covered(instrs, fun) do
    instrs
    |> Enum.with_index()
    |> Enum.filter(fn {instr, _at} -> total_handler?(instrs, instr) end)
    |> Enum.reduce(MapSet.new(), fn {{op, reg, _handler}, at}, acc ->
      {:done, visited} =
        Walk.explore(fun, instrs, [at + 1],
          on_instr: fn instr, i ->
            if i == at or region_end?(op, reg, instr), do: :prune, else: :continue
          end
        )

      MapSet.union(acc, visited)
    end)
  end

  defp total_handler?(_instrs, {:catch, _reg, {:f, _label}}), do: true

  defp total_handler?(instrs, {:try, _reg, {:f, label}}) do
    totals = CatchClauses.analyse(instrs, label).totals
    :* in totals or Enum.all?(@classes, &(&1 in totals))
  end

  defp total_handler?(_instrs, _instr), do: false

  defp region_end?(:try, reg, {:try_end, reg}), do: true
  defp region_end?(:try, reg, {:try_case, reg}), do: true
  defp region_end?(:catch, reg, {:catch_end, reg}), do: true
  defp region_end?(_op, _reg, _instr), do: false
end
