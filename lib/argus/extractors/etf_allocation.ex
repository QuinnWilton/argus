defmodule Argus.Extractors.EtfAllocation do
  @moduledoc """
  ETF decoder sites and operation-specific compressed-prefix exclusions.

  The decoder API includes wrappers which reject executable terms: that rejection
  occurs after ETF materialization and does not bound decompression. Local pure
  delegates are followed so a guard before the delegate remains tied to its bytes.
  A checked local predicate proves exclusion only if, assuming compressed input,
  every reachable completion returns a different known literal or does not return.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractors.EtfAllocation.Prefix
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @apis for {mod, fun, arities} <- [
              {:erlang, :binary_to_term, [1, 2]},
              {Plug.Crypto, :non_executable_binary_to_term, [1, 2]},
              {Plug.Crypto, :safe_binary_to_term, [1, 2]},
              {Ash.Helpers, :non_executable_binary_to_term, [1, 2]}
            ],
            arity <- arities,
            into: %{},
            do: {{mod, fun, arity}, "#{inspect(mod)}.#{fun}/#{arity}"}

  @impl true
  def relations, do: [:etf_decode_site, :etf_compression_rejected]

  @impl true
  def extract(module_data) do
    calls = CallSites.for_module(module_data)
    targets = decoder_targets(module_data, calls)
    candidates = Enum.filter(calls, &Map.has_key?(targets, &1.mfa))

    if candidates == [] do
      %{}
    else
      functions = functions(module_data)
      callers = MapSet.new(candidates, & &1.mfa)
      captured = captured_targets(module_data)

      # Only closed delegates can move their evidence to direct callers. A
      # captured function can also receive unchecked bytes through a callback.
      delegate_bodies =
        for {:function, name, arity, _, _} <- module_data.functions,
            mfa = {module_data.module, name, arity},
            Map.has_key?(targets, mfa),
            MapSet.member?(callers, mfa),
            not MapSet.member?(captured, mfa),
            not Enum.any?(module_data.exports, &(elem(&1, 0) == name and elem(&1, 1) == arity)),
            into: MapSet.new(),
            do: InstrId.func_id(module_data.module, name, arity)

      candidates
      |> Enum.reject(&MapSet.member?(delegate_bodies, &1.func_id))
      |> Enum.reduce(%{}, fn site, facts ->
        id = InstrId.mint(site.func_id, site.idx)
        fun = Map.fetch!(functions, site.func_id)

        facts =
          add_fact(facts, :etf_decode_site, [id, site.func_id, Map.fetch!(targets, site.mfa)])

        if rejects_compressed?(site, fun, functions),
          do: add_fact(facts, :etf_compression_rejected, [id, site.func_id]),
          else: facts
      end)
      |> Map.new(fn {relation, rows} -> {relation, rows |> Enum.uniq() |> Enum.sort()} end)
    end
  end

  defp captured_targets(data) do
    for {:function, _, _, _, instrs} <- data.functions,
        {:make_fun3, target, _, _, _, _} <- instrs,
        into: MapSet.new(),
        do: target
  end

  defp functions(data) do
    Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
      cfg = data |> Helpers.cfg(name, arity) |> SecurityValues.proof_cfg(instrs)

      {InstrId.func_id(data.module, name, arity),
       %{instrs: instrs, cfg: cfg, states: Prefix.states(cfg, instrs)}}
    end)
  end

  defp decoder_targets(data, calls) do
    delegates =
      for {:function, name, arity, _, instrs} <- data.functions,
          func = InstrId.func_id(data.module, name, arity),
          [site] <- [Enum.filter(calls, &(&1.func_id == func))],
          Instr.tail_call?(Enum.at(instrs, site.idx)),
          SecurityValues.identity_at(instrs, site.idx, {:x, 0}) == {:param, 0},
          Enum.all?(instrs, &delegate_instruction?/1),
          do: {{data.module, name, arity}, site.mfa}

    grow_targets(delegates, @apis)
  end

  defp grow_targets(delegates, targets) do
    next =
      Enum.reduce(delegates, targets, fn {func, callee}, acc ->
        case Map.fetch(targets, callee) do
          {:ok, api} -> Map.put(acc, func, api)
          :error -> acc
        end
      end)

    if next == targets, do: targets, else: grow_targets(delegates, next)
  end

  defp delegate_instruction?(instr) do
    Instr.tail_call?(instr) or
      (is_tuple(instr) and
         elem(instr, 0) in [:label, :line, :debug_line, :executable_line, :func_info, :move])
  end

  defp rejects_compressed?(_site, %{states: :unknown}, _functions), do: false

  defp rejects_compressed?(site, fun, functions) do
    with state when is_map(state) <- Map.get(fun.states, site.idx),
         value when value != nil <- Prefix.value(state, {:x, 0}) do
      unreachable_with_prefix?(fun, site.idx, value) or
        accepted_predicate_excludes?(fun, site.idx, value, functions)
    else
      _ -> false
    end
  end

  defp unreachable_with_prefix?(fun, idx, value) do
    case Prefix.states(fun.cfg, fun.instrs, value) do
      :unknown -> false
      states -> not Map.has_key?(states, idx)
    end
  end

  defp accepted_predicate_excludes?(fun, use, value, functions) do
    fun.instrs
    |> Enum.with_index()
    |> Enum.any?(fn
      {{:test, op, _, [a, b]}, at} when op in [:is_eq_exact, :is_ne_exact] ->
        with state when is_map(state) <- Map.get(fun.states, at),
             {call, accepted} <- call_and_literal(Prefix.value(state, a), Prefix.value(state, b)),
             edge = if(op == :is_eq_exact, do: :branch_pass, else: :branch_fail),
             true <- SecurityValues.edge_covers?(fun.cfg, at, edge, use) do
          excludes_at_call?(fun, call, value, accepted, functions)
        else
          _ -> false
        end

      _ ->
        false
    end)
  end

  defp call_and_literal({:call, call}, {:literal, accepted}), do: {call, accepted}
  defp call_and_literal({:literal, accepted}, {:call, call}), do: {call, accepted}
  defp call_and_literal(_, _), do: nil

  defp excludes_at_call?(fun, at, value, accepted, functions) do
    with {:ok, mod, name, arity} <- Helpers.match_local_call(Enum.at(fun.instrs, at)),
         %{states: states} = predicate when states != :unknown <-
           Map.get(functions, InstrId.func_id(mod, name, arity)),
         state when is_map(state) <- Map.get(fun.states, at) do
      Enum.any?(0..(arity - 1)//1, fn pos ->
        Prefix.value(state, {:x, pos}) == value and
          cannot_return?(predicate, pos, accepted)
      end)
    else
      _ -> false
    end
  end

  defp cannot_return?(fun, pos, accepted) do
    case Prefix.states(fun.cfg, fun.instrs, {:param, pos}) do
      :unknown ->
        false

      states ->
        Enum.all?(states, fn {at, state} ->
          instr = Enum.at(fun.instrs, at)

          cond do
            instr == :return ->
              case Prefix.value(state, {:x, 0}) do
                {:literal, actual} -> actual != accepted
                _ -> false
              end

            Instr.tail_call?(instr) ->
              false

            true ->
              true
          end
        end)
    end
  end
end
