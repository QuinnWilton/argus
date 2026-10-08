defmodule Argus.Extractors.ParamFlow.PrivateBounds do
  @moduledoc false

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ParamFlow.Bounded
  alias Argus.Instr
  alias Argus.InstrId
  # An unexported function that is never captured has only the direct callers
  # visible in its module. Each parameter can inherit the union of their finite
  # argument sets, provided every invocation establishes that bound. Start with
  # unknown parameters, so cycles cannot prove themselves bounded. A fixed round
  # limit only loses additional refinements: every retained proof already holds
  # without assuming anything about callers whose parameters remain unknown.
  @rounds 12

  @spec entries(Argus.Extractor.module_data(), [String.t()]) ::
          {%{String.t() => Bounded.bounds()}, Bounded.return_bounds()}
  def entries(_data, []), do: {%{}, %{}}

  def entries(%{module: mod, functions: functions} = data, sinks) do
    blocked = externally_callable(data)

    calls =
      data
      |> CallSites.for_module()
      |> Enum.filter(fn %{mfa: {m, f, a}} -> m == mod and {f, a} not in blocked end)
      |> Enum.group_by(fn %{mfa: {m, f, a}} -> InstrId.func_id(m, f, a) end)

    relevant = ancestors(sinks, calls, %{})

    targets =
      calls
      |> Enum.filter(fn {_target, sites} ->
        Enum.any?(sites, &Map.has_key?(relevant, &1.func_id))
      end)
      |> Enum.map(&elem(&1, 0))

    relevant = ancestors(targets, calls, relevant)
    calls = Map.take(calls, Map.keys(relevant))

    functions =
      Map.new(functions, fn {:function, name, arity, _, instrs} ->
        {InstrId.func_id(mod, name, arity),
         {{mod, name, arity}, instrs, Helpers.cfg(data, name, arity)}}
      end)

    solve(calls, functions, %{}, %{}, @rounds)
  end

  defp externally_callable(data) do
    exports = for {f, a, _label} <- data.exports, do: {f, a}

    captured =
      for {:function, _, _, _, instrs} <- data.functions,
          {:make_fun3, {m, f, a}, _, _, _, _} <- instrs,
          m == data.module,
          do: {f, a}

    exports ++ captured
  end

  defp ancestors([], _calls, seen), do: seen

  defp ancestors([func | rest], calls, seen) do
    if Map.has_key?(seen, func) do
      ancestors(rest, calls, seen)
    else
      callers = Enum.map(Map.get(calls, func, []), & &1.func_id)
      ancestors(callers ++ rest, calls, Map.put(seen, func, true))
    end
  end

  defp solve(_calls, _functions, entries, returns, 0), do: {entries, returns}

  defp solve(calls, functions, entries, returns, rounds) do
    bounds =
      calls
      |> Map.values()
      |> List.flatten()
      |> Enum.group_by(& &1.func_id)
      |> Map.new(fn {func, sites} ->
        {{_mod, _name, arity}, instrs, cfg} = Map.fetch!(functions, func)
        indexes = sites |> Enum.map(& &1.idx) |> Enum.uniq()
        entry = Map.get(entries, func, %{})
        {func, if(cfg, do: Bounded.at(cfg, instrs, arity, indexes, entry, returns), else: %{})}
      end)

    refined =
      Map.new(calls, fn {target, sites} ->
        inherited =
          Enum.map(sites, fn site ->
            {_mod, _name, arity} = site.mfa
            regs = Enum.map(0..(arity - 1)//1, &{:x, &1})

            bounds
            |> Map.fetch!(site.func_id)
            |> Map.get(site.idx, %{})
            |> Map.take(regs)
            |> Map.filter(fn {_reg, bound} -> match?({:values, _}, bound) end)
          end)

        {target, Bounded.common_entries(inherited)}
      end)

    returned = return_bounds(Map.take(functions, Map.keys(calls)), entries, returns)

    if refined == entries and returned == returns,
      do: {entries, returns},
      else: solve(calls, functions, refined, returned, rounds - 1)
  end

  # A return summary must cover every completing path. Functions with tail
  # calls are left unknown here; their result would need the callee's own proof.
  defp return_bounds(functions, entries, returns) do
    Enum.reduce(functions, %{}, fn {func, {mfa, instrs, cfg}}, acc ->
      indexes = for {:return, idx} <- Enum.with_index(instrs), do: idx

      if cfg && indexes != [] && not Enum.any?(instrs, &Instr.tail_call?/1) do
        {_mod, _name, arity} = mfa
        states = Bounded.at(cfg, instrs, arity, indexes, Map.get(entries, func, %{}), returns)
        values = Enum.map(indexes, &Map.take(Map.get(states, &1, %{}), [{:x, 0}]))

        case Bounded.common_entries(values) do
          %{{:x, 0} => {:values, _} = bound} -> Map.put(acc, mfa, bound)
          _ -> acc
        end
      else
        acc
      end
    end)
  end
end
