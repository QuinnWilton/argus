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
  argument register (`Resolve.fun_origin/3`). A call does not count when
  its result carries that argument (`Argus.Extractors.ParamFlow.
  Propagators`): `Keyword.get(opts, :on_fail, &Defaults.on_fail/2)` hands
  the fun back to be stored, and the function that stores a callback
  does not run it. Neither does a fun built into a tuple, list or map, or
  one held in a literal table. A local capture (`&helper/1`) is a
  `make_fun3`, which the emitter already records as `closure_def`. A
  function that also calls the target directly gets no row: the call
  relations already give that edge, and a rule that sets fun-held edges
  aside (a fun may run in another process) must not lose the call.

  `fun_handed` rows name the call itself: the call at `id` that is handed
  the fun, closures included. A call graph edge through a fun has no call
  instruction of its own, so a rule that asks whether that edge is
  guarded (a `try` around it) holds it against the call the fun is handed
  to — `Enum.each(peers, fn p -> ... end)` runs the closure inside
  `Enum.each`, and only a try around that call catches what it raises.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
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
        refs =
          for {:external, callee, _pos} <- handed(instrs, idx, instr),
              reduce: refs,
              do: (acc -> MapSet.put(acc, callee))

        {refs, called(instr, called)}
      end)

    refs
    |> MapSet.difference(called)
    |> Enum.sort()
    |> Enum.map(&[func_id, &1])
  end

  @doc """
  One `[id, caller, callee, pos]` row per argument of a call in
  `normalized` that is handed a fun that runs `callee`: a closure the
  function builds (`make_fun3`) or a literal external fun, in an argument
  position `pos` the call's result does not carry. Sorted and without
  duplicates.
  """
  @spec handed_rows(String.t(), [{String.t(), tuple() | atom()}]) :: [[String.t()]]
  def handed_rows(func_id, normalized) do
    instrs = Enum.map(normalized, fn {_id, instr} -> instr end)

    normalized
    |> Enum.with_index()
    |> Enum.flat_map(fn {{id, instr}, idx} ->
      for {_kind, callee, pos} <- handed(instrs, idx, instr),
          do: [id, func_id, callee, to_string(pos)]
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # The funs a call at `idx` is handed in argument positions its result
  # does not carry, as `{kind, callee, pos}`: `:closure` for a
  # `make_fun3`, `:external` for a literal or `erlang:make_fun/3`
  # external fun.
  defp handed(instrs, idx, instr) do
    case callee(instr) do
      {:ok, {mod, fun, arity}, carried} ->
        for pos <- 0..(arity - 1)//1,
            pos not in carried,
            {kind, {m, f, a}} <- [Resolve.fun_origin(instrs, idx, {:x, pos})],
            kind in [:closure, :external],
            not (m == mod and f == fun and a == arity),
            do: {kind, InstrId.func_id(m, f, a), pos}

      :none ->
        []
    end
  end

  defp callee(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, fun, arity} ->
        {:ok, {mod, fun, arity},
         Propagators.positions(inspect(mod), InstrId.name(fun), arity) || []}

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
