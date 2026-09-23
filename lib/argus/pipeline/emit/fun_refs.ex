defmodule Argus.Pipeline.Emit.FunRefs do
  @moduledoc """
  The `fun_ref` rows of one function: the functions it hands, as fun
  values, to a call that may invoke them, without calling them itself.

  `Enum.map(list, &URI.parse/1)` calls `URI.parse/1` through `Enum.map`,
  but the bytecode says only `move {literal, &URI.parse/1}` and a call to
  `Enum.map/2`: no call relation names `URI.parse/1`, so the call graph
  stopped at `Enum.map`. Handed to a call, a fun is an edge the call
  graph follows the way it follows a closure's `closure_def`.

  A fun is an external fun (`&Mod.f/1`, a literal) or the result of
  `erlang:make_fun/3` of literals, followed through copies to an
  argument register (`Helpers.fun_origin/3`). A call does not count when
  its result carries that argument (`Argus.Extractors.ParamFlow.
  Propagators`): `Keyword.get(opts, :on_fail, &Defaults.on_fail/2)` hands
  the fun back to be stored, and the function that stores a callback
  does not run it. Neither does a fun built into a tuple, list or map, or
  one held in a literal table. A local capture (`&helper/1`) is a
  `make_fun3`, which the emitter already records as `closure_def`. A
  function that also calls the target directly gets no row: the call
  relations already give that edge, and a rule that sets fun-held edges
  aside (a fun may run in another process) must not lose the call.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.InstrId

  @doc """
  One `[caller, callee]` row per function `normalized` (the function's
  `{id, instruction}` pairs) hands to a call and does not call.
  """
  @spec rows(String.t(), [{String.t(), tuple() | atom()}]) :: [[String.t()]]
  def rows(func_id, normalized) do
    instrs = Enum.map(normalized, fn {_id, instr} -> instr end)

    {refs, called} =
      instrs
      |> Enum.with_index()
      |> Enum.reduce({MapSet.new(), MapSet.new()}, fn {instr, idx}, {refs, called} ->
        refs = Enum.reduce(handed(instrs, idx, instr), refs, &MapSet.put(&2, &1))
        {refs, called(instr, called)}
      end)

    refs
    |> MapSet.difference(called)
    |> Enum.sort()
    |> Enum.map(&[func_id, &1])
  end

  # The funs a call at `idx` is handed in argument positions its result
  # does not carry.
  defp handed(instrs, idx, instr) do
    case callee(instr) do
      {:ok, {mod, fun, arity}, carried} ->
        for pos <- 0..(arity - 1)//1,
            pos not in carried,
            {kind, {m, f, a}} <- [Helpers.fun_origin(instrs, idx, {:x, pos})],
            kind == :external,
            not (m == mod and f == fun and a == arity),
            do: InstrId.func_id(m, f, a)

      :none ->
        []
    end
  end

  defp callee(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, fun, arity} ->
        {:ok, {mod, fun, arity}, Propagators.positions(inspect(mod), to_string(fun), arity) || []}

      :none ->
        case Helpers.match_local_call(instr) do
          {:ok, mod, fun, arity} -> {:ok, {mod, fun, arity}, []}
          :none -> :none
        end
    end
  end

  defp called({:bif, name, _fail, args, _dst}, called) when is_list(args),
    do: MapSet.put(called, InstrId.func_id(:erlang, name, length(args)))

  defp called({:gc_bif, name, _fail, _live, args, _dst}, called) when is_list(args),
    do: MapSet.put(called, InstrId.func_id(:erlang, name, length(args)))

  defp called(instr, called) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, fun, arity} ->
        MapSet.put(called, InstrId.func_id(mod, fun, arity))

      :none ->
        case Helpers.match_local_call(instr) do
          {:ok, mod, fun, arity} -> MapSet.put(called, InstrId.func_id(mod, fun, arity))
          :none -> called
        end
    end
  end
end
