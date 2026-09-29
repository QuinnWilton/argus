defmodule Argus.Extractor.Answers do
  @moduledoc """
  Which calls' answers a value is: the one reading of a wrapper.

  A value is an answer of the call at `site`, `depth` payloads down, when
  the write that made it is:

  - the call's result (`depth` 0);
  - the payload of that result, the element after its tag (`depth` 1:
    the `pid` of `{:ok, pid} = start()`);
  - that payload re-wrapped under a literal tag (`depth` 0: `{:ok, pid} =
    start(); {:ok, pid}`, and the `{:error, reason}` a `case` rebuilds
    from the result's own reason).

  Every write that may reach the value is read, on every path (copies —
  `move`, `swap`, `trim` — followed): the value's answers are the union
  of theirs, and one write of anything else — a parameter, a literal, a
  lookup, a fun's result, a deeper element — makes the value no answer
  at all. So a value with answers is, on every path, one of them: `{:ok,
  pid} = if pool, do: DynamicSupervisor.start_child(pool, spec), else:
  Worker.start_link(arg)` is the answer of either start. A deeper
  element is left out on purpose: the pid of `{:error, {:already_started,
  pid}}` is an element of an element, and names a process someone else
  started.

  A function answers its calls when each way it returns a value hands
  back an answer (`function_answers/1`): a tail call (a default-argument
  wrapper, `def start(opts), do: DynamicSupervisor.start_child(...)`), or
  a `return` of a result, a payload or a re-wrap, through a `case` or a
  `with` that passes each arm on. A path that raises returns nothing and
  is not asked; a tail call to `erlang:error/1,2`, `exit/1`, `throw/1`,
  `raise/3` or `nif_error/1` raises. One return of anything else (a
  lookup of a running process, a literal, a parameter) and the function
  answers nothing: a lookup-or-start wrapper hands back a process others
  hold on its lookup path (review 2, item 25).

  The rules chain these through the program (`clientlib/answers.dl`): a
  call to a function that answers calls answers what they answered, as
  many layers down as the program has.
  """

  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @typedoc "An answer: the call's instruction index and how many payloads down."
  @type answer :: {non_neg_integer(), 0 | 1}

  # Calls that never return: a tail call to one raises instead.
  @raising [error: 1, error: 2, exit: 1, throw: 1, raise: 3, nif_error: 1]

  # How many writes one question reads before it gives up: a function's
  # code is finite, but a chain of projections and re-wraps through a loop
  # is cut short rather than followed around it.
  @fuel 256

  @doc """
  The answers `register` holds at `idx`, before the instruction there
  runs: on every path one of them, sorted. Empty when some path holds
  anything else.
  """
  @spec answered([Instr.instr()], non_neg_integer(), Resolve.register()) :: [answer()]
  def answered(instrs, idx, register) do
    case answers(instrs, idx, register, @fuel) do
      {:ok, set, _fuel} -> Enum.sort(set)
      :none -> []
    end
  end

  # The answers every write of `reg` reaching `idx` may make, or :none.
  defp answers(_instrs, _idx, _reg, fuel) when fuel <= 0, do: :none

  defp answers(instrs, idx, reg, fuel) do
    instrs
    |> Resolve.writers(idx, reg)
    |> Enum.reduce_while({:ok, [], fuel - 1}, fn writer, {:ok, acc, fuel} ->
      case written(instrs, writer, fuel) do
        {:ok, more, fuel} -> {:cont, {:ok, Enum.uniq(more ++ acc), fuel}}
        :none -> {:halt, :none}
      end
    end)
    |> case do
      {:ok, [], _fuel} -> :none
      answer -> answer
    end
  end

  # A call's result, a payload of one, or a payload re-wrapped under a
  # literal tag.
  defp written(_instrs, {:param, _position}, _fuel), do: :none

  defp written(instrs, at, fuel) do
    case Reaching.at(instrs, at) do
      {:call, _arity, _target} ->
        {:ok, [{at, 0}], fuel}

      {:call_ext, _arity, _target} ->
        {:ok, [{at, 0}], fuel}

      {:get_tuple_element, src, 1, _dst} ->
        down(instrs, at, src, fuel, 0, 1)

      {:put_tuple2, _dst, {:list, [{:atom, _tag}, payload]}} ->
        case register(payload) do
          nil -> :none
          reg -> down(instrs, at, reg, fuel, 1, 0)
        end

      _other ->
        :none
    end
  end

  # The answers of `reg` at `at`, each of which must be `from` payloads
  # down, moved to `to`.
  defp down(instrs, at, reg, fuel, from, to) do
    with reg when reg != nil <- register(reg),
         {:ok, set, fuel} <- answers(instrs, at, reg, fuel),
         true <- Enum.all?(set, fn {_site, depth} -> depth == from end) do
      {:ok, Enum.map(set, fn {site, _depth} -> {site, to} end), fuel}
    else
      _ -> :none
    end
  end

  defp register({:tr, reg, _type}), do: register(reg)
  defp register({kind, _n} = reg) when kind in [:x, :y], do: reg
  defp register(_operand), do: nil

  @doc """
  The answers every way the function returns a value hands back, sorted:
  empty when a return hands back anything else, or when the function
  never returns a value.
  """
  @spec function_answers([Instr.instr()]) :: [answer()]
  def function_answers(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce_while([], fn {instr, idx}, acc ->
      case exit_answers(instrs, instr, idx) do
        :none -> {:halt, :none}
        more -> {:cont, more ++ acc}
      end
    end)
    |> case do
      :none -> []
      found -> found |> Enum.uniq() |> Enum.sort()
    end
  end

  # What a way out of the function hands back: a return's x0, or a tail
  # call's own answer. A tail call that raises, and every instruction
  # that is not a way out, hands back nothing and is left out.
  defp exit_answers(instrs, :return, idx) do
    case answered(instrs, idx, {:x, 0}) do
      [] -> :none
      set -> set
    end
  end

  defp exit_answers(_instrs, instr, idx) do
    cond do
      not Instr.tail_call?(instr) -> []
      raising?(instr) -> []
      match?({:apply_last, _, _}, instr) -> :none
      true -> [{idx, 0}]
    end
  end

  defp raising?({:call_ext_only, _arity, {:extfunc, :erlang, name, arity}}),
    do: {name, arity} in @raising

  defp raising?({:call_ext_last, _arity, {:extfunc, :erlang, name, arity}, _dealloc}),
    do: {name, arity} in @raising

  defp raising?(_instr), do: false
end
