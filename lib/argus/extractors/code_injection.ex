defmodule Argus.Extractors.CodeInjection do
  @moduledoc """
  Template compiler sites and exact conditions on same-module call invocations.

  Conditions are necessary equalities established on every path to the operation.
  The rules substitute literal flags at each caller, preserving the difference
  between evaluating a configured template and forwarding runtime content verbatim.
  """
  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Terms
  alias Argus.Extractors.SecurityValues
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations, do: [:code_template_site, :code_call, :code_arg_identity, :code_site_gate]

  @impl true
  def extract(data) do
    sites = CallSites.for_module(data)

    if Enum.any?(sites, &template?(&1.mfa)) do
      functions =
        Map.new(data.functions, fn {:function, name, arity, _, instrs} ->
          cfg = SecurityValues.proof_cfg(Helpers.cfg(data, name, arity), instrs)
          {InstrId.func_id(data.module, name, arity), {cfg, checks(instrs)}}
        end)

      sites
      |> Enum.filter(&(elem(&1.mfa, 0) == data.module or template?(&1.mfa)))
      |> Enum.reduce(%{}, &emit(&2, &1, functions))
      |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
    else
      %{}
    end
  end

  defp template?({EEx, :eval_string, arity}), do: arity in [1, 2, 3]
  defp template?({EEx, :compile_string, arity}), do: arity in [1, 2]
  defp template?(_mfa), do: false

  defp emit(facts, site, functions) do
    {mod, name, arity} = site.mfa
    id = InstrId.mint(site.func_id, site.idx)
    facts = add_fact(facts, :code_call, [id, site.func_id, InstrId.func_id(mod, name, arity)])

    facts =
      if template?(site.mfa),
        do:
          add_fact(facts, :code_template_site, [
            id,
            site.func_id,
            "#{inspect(mod)}.#{name}/#{arity}"
          ]),
        else: facts

    facts =
      for pos <- 0..(arity - 1)//1, reduce: facts do
        acc ->
          {kind, value} =
            case SecurityValues.identity_at(site.instrs, site.idx, {:x, pos}) do
              {:param, param} -> {"param", to_string(param)}
              {:literal, literal} -> {"literal", Terms.spell(literal)}
              _ -> {"unknown", ""}
            end

          add_fact(acc, :code_arg_identity, [id, site.func_id, to_string(pos), kind, value])
      end

    {cfg, checks} = Map.fetch!(functions, site.func_id)

    gate =
      checks
      |> Enum.filter(fn {at, edge, _, _} ->
        SecurityValues.edge_covers?(cfg, at, edge, site.idx)
      end)
      |> Enum.map(fn {_, _, param, value} -> {param, value} end)
      |> Enum.sort()
      |> List.first({-1, ""})

    {param, value} = gate
    add_fact(facts, :code_site_gate, [id, site.func_id, to_string(param), value])
  end

  defp checks(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:test, op, _, [left, right]}, at} when op in [:is_eq_exact, :is_ne_exact] ->
        edge = if op == :is_eq_exact, do: :branch_pass, else: :branch_fail

        case {SecurityValues.identity_at(instrs, at, left),
              SecurityValues.identity_at(instrs, at, right)} do
          {{:param, param}, {:literal, value}} -> [{at, edge, param, Terms.spell(value)}]
          {{:literal, value}, {:param, param}} -> [{at, edge, param, Terms.spell(value)}]
          _ -> []
        end

      {{:select_val, src, _, {:list, arms}}, at} ->
        case SecurityValues.identity_at(instrs, at, src) do
          {:param, param} ->
            for [literal, _label] <- Enum.chunk_every(arms, 2),
                {:literal, value} <- [SecurityValues.identity_at(instrs, at, literal)],
                spelled = Terms.spell(value),
                do: {at, {:select_arm, spelled}, param, spelled}

          _ ->
            []
        end

      _ ->
        []
    end)
  end
end
