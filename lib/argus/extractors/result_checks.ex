defmodule Argus.Extractors.ResultChecks do
  @moduledoc """
  Call-result uses and exact literal preconditions at those uses.

  A tuple's shape is different from its success field. Projections retain their
  originating invocation, and a check only protects uses reached through its
  accepting edge on every path. Copies and projections are not payload uses;
  consuming a field is distinct from forwarding the complete result.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Terms
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations do
    [
      :security_result,
      :security_result_use,
      :security_result_precondition,
      :security_result_exclusion,
      :security_result_discarded
    ]
  end

  @impl true
  def extract(module_data) do
    sites = Enum.group_by(CallSites.for_module(module_data), & &1.func_id)

    module_data.functions
    |> Enum.reduce(%{}, fn {:function, name, arity, _entry, instrs}, facts ->
      func = InstrId.func_id(module_data.module, name, arity)
      calls = Map.get(sites, func, [])

      if calls == [] do
        facts
      else
        cfg = SecurityValues.proof_cfg(Helpers.cfg(module_data, name, arity), instrs)
        uses = uses(instrs)
        checks = checks(instrs)

        Enum.reduce(calls, facts, &emit_result(&2, &1, cfg, uses, checks))
      end
    end)
    |> Map.new(fn {relation, rows} -> {relation, Enum.sort(Enum.uniq(rows))} end)
  end

  defp emit_result(facts, site, cfg, uses, checks) do
    id = InstrId.mint(site.func_id, site.idx)
    {mod, name, arity} = site.mfa

    facts =
      add_fact(facts, :security_result, [id, site.func_id, InstrId.func_id(mod, name, arity)])

    facts =
      if Instr.tail_call?(Enum.at(site.instrs, site.idx)) do
        add_fact(facts, :security_result_use, [id, site.func_id, id, "self", "forward"])
      else
        facts
      end

    facts =
      Enum.reduce(Map.get(uses, site.idx, []), facts, fn {at, path, kind}, acc ->
        use = InstrId.mint(site.func_id, at)
        acc = add_fact(acc, :security_result_use, [id, site.func_id, use, path, kind])

        Enum.reduce(Map.get(checks, site.idx, []), acc, fn {check, edge, field, value, relation},
                                                           rows ->
          if SecurityValues.edge_covers?(cfg, check, edge, at) do
            add_check_fact(rows, relation, [
              id,
              site.func_id,
              use,
              field,
              Terms.spell(value)
            ])
          else
            rows
          end
        end)
      end)

    case discarded_at(site) do
      nil ->
        facts

      at ->
        add_fact(facts, :security_result_discarded, [
          id,
          site.func_id,
          InstrId.mint(site.func_id, at)
        ])
    end
  end

  defp add_check_fact(facts, :security_result_precondition, row),
    do: add_fact(facts, :security_result_precondition, row)

  defp add_check_fact(facts, :security_result_exclusion, row),
    do: add_fact(facts, :security_result_exclusion, row)

  defp uses(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {instr, at} ->
      case use_kind(instr) do
        nil ->
          []

        kind ->
          for reg <- Instr.uses(instr),
              {origin, path} <-
                List.wrap(result_path(SecurityValues.identity_at(instrs, at, reg))),
              do:
                {origin,
                 {at, path, if(path == "self" and kind == "value", do: "forward", else: kind)}}
      end
    end)
    |> Enum.uniq()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp use_kind(instr) do
    cond do
      copy?(instr) or projection?(instr) -> nil
      match?({:test, _, _, _}, instr) -> "test"
      match?({:select_val, _, _, _}, instr) -> "test"
      match?({:select_tuple_arity, _, _, _}, instr) -> "test"
      raises?(instr) -> "raise"
      Instr.known?(instr) -> "value"
      true -> nil
    end
  end

  defp raises?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, :error, arity} when arity in [1, 2, 3] ->
        true

      {:ok, :erlang, name, 1} when name in [:throw, :exit] ->
        true

      _ ->
        not Instr.falls_through?(instr) and not Instr.exits?(instr) and Instr.targets(instr) == []
    end
  end

  defp copy?(instr), do: Enum.any?(Instr.defs(instr), &(Instr.copy_source(instr, &1) != nil))

  defp projection?({:get_tuple_element, _, _, _}), do: true
  defp projection?({:get_map_elements, _, _, _}), do: true
  defp projection?({:bif, name, _, _, _}) when name in [:element, :map_get], do: true
  defp projection?({:gc_bif, name, _, _, _, _}) when name in [:element, :map_get], do: true
  defp projection?(_), do: false

  defp checks(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:test, :is_tagged_tuple, _, [src, _size, {:atom, tag}]}, at} ->
        check(instrs, at, src, :branch_pass, tag, [{:tuple, 0}])

      {{:test, op, _, [left, right]}, at} when op in [:is_eq_exact, :is_ne_exact] ->
        edge = if op == :is_eq_exact, do: :branch_pass, else: :branch_fail
        equality_check(instrs, at, left, right, edge)

      {{:select_val, src, _, {:list, arms}}, at} ->
        Enum.flat_map(Enum.chunk_every(arms, 2), fn [literal, _label] ->
          case SecurityValues.identity_at(instrs, at, literal) do
            {:literal, value} ->
              check(instrs, at, src, {:select_arm, Terms.spell(value)}, value) ++
                check(instrs, at, src, :select_fail, value, [], :security_result_exclusion)

            _ ->
              []
          end
        end)

      _ ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp equality_check(instrs, at, left, right, edge) do
    case {SecurityValues.identity_at(instrs, at, left),
          SecurityValues.identity_at(instrs, at, right)} do
      {_, {:literal, value}} -> equality_edges(instrs, at, left, edge, value)
      {{:literal, value}, _} -> equality_edges(instrs, at, right, edge, value)
      _ -> []
    end
  end

  defp equality_edges(instrs, at, src, edge, value) do
    other = if edge == :branch_pass, do: :branch_fail, else: :branch_pass

    check(instrs, at, src, edge, value) ++
      check(instrs, at, src, other, value, [], :security_result_exclusion)
  end

  defp check(
         instrs,
         at,
         src,
         edge,
         value,
         suffix \\ [],
         relation \\ :security_result_precondition
       ) do
    case result_fields(SecurityValues.identity_at(instrs, at, src)) do
      {origin, fields} -> [{origin, {at, edge, path(fields ++ suffix), value, relation}}]
      nil -> []
    end
  end

  defp result_path(identity) do
    case result_fields(identity) do
      {origin, fields} -> {origin, path(fields)}
      nil -> nil
    end
  end

  defp result_fields({:call, at}), do: {at, []}

  defp result_fields({:field, parent, kind, key}) do
    case result_fields(parent) do
      {origin, fields} -> {origin, fields ++ [{kind, key}]}
      nil -> nil
    end
  end

  defp result_fields(_), do: nil

  defp path([]), do: "self"

  defp path(fields) do
    Enum.map_join(fields, "/", fn
      {:tuple, index} -> "tuple:#{index}"
      {:map, key} -> "map:" <> Terms.spell(key)
    end)
  end

  # This is a positive, deliberately narrow proof. Unknown instructions,
  # branching, or an actual read stop it. A saved result can still be discarded
  # when its last copy is overwritten; a forwarded or checked result cannot.
  defp discarded_at(site) do
    if Instr.call?(Enum.at(site.instrs, site.idx)) do
      site.instrs
      |> Enum.drop(site.idx + 1)
      |> Enum.with_index(site.idx + 1)
      |> discard_walk([{:x, 0}])
    end
  end

  defp discard_walk([], _aliases), do: nil

  defp discard_walk([{instr, at} | rest], aliases) do
    read? = Enum.any?(Instr.uses(instr), &(&1 in aliases))
    next = Instr.carry(instr, aliases)

    cond do
      not Instr.known?(instr) -> nil
      read? and not copy?(instr) -> nil
      Instr.targets(instr) != [] -> nil
      next == [] -> at
      Instr.exits?(instr) -> at
      not Instr.falls_through?(instr) -> nil
      true -> discard_walk(rest, next)
    end
  end
end
