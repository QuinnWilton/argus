defmodule Argus.Extractors.Supervision do
  @moduledoc """
  Supervision tree extractor.

  Analyzes modules that implement the `Supervisor` behaviour to extract
  child specifications, restart strategies, and supervision structure.

  ## Approach

  Reads the module's attributes to detect `@behaviour Supervisor`, then
  inspects the `init/1` function's literal table for child spec data.
  Since child specs are often built at compile time and stored in the
  literal table, we can extract them without full dataflow analysis.

  ## Emitted facts

  - `supervisor(mod, strategy)` — module is a supervisor with given strategy
  - `supervisor_child(sup, position, child_mod, restart, type)` — child spec
  - `named_process(mod, name)` — named process registration detected
  """

  @behaviour Argus.Extractor

  @strategies [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]

  @impl true
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    attrs = module_data.attributes

    # Only process supervisor modules.
    behaviours =
      (Keyword.get_values(attrs, :behaviour) ++ Keyword.get_values(attrs, :behavior))
      |> List.flatten()

    if Supervisor in behaviours do
      extract_supervisor(mod_str, module_data)
    else
      %{}
    end
  end

  defp extract_supervisor(mod_str, module_data) do
    functions = module_data.functions
    facts = %{}

    # Find init/1 function and scan for supervision patterns.
    init_func =
      Enum.find(functions, fn
        {:function, :init, 1, _, _} -> true
        _ -> false
      end)

    case init_func do
      nil ->
        # Supervisor without init/1 — just record the behaviour.
        add_fact(facts, :supervisor, [mod_str, "unknown"])

      {:function, :init, 1, _, instrs} ->
        facts = extract_from_init(facts, mod_str, instrs)
        facts
    end
  end

  defp extract_from_init(facts, mod_str, instrs) do
    # Look for the strategy in literal values or atoms moved before
    # the Supervisor.init call.
    strategy = detect_strategy(instrs)
    facts = add_fact(facts, :supervisor, [mod_str, to_string(strategy)])

    # Extract child specs from literal table values in the instructions.
    children = extract_children(instrs)

    children
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {{child_mod, restart, type}, idx}, acc ->
      add_fact(acc, :supervisor_child, [
        mod_str,
        to_string(idx),
        inspect(child_mod),
        to_string(restart),
        to_string(type)
      ])
    end)
  end

  # Detect the supervision strategy from init/1 instructions.
  # Look for atoms like :one_for_one, :one_for_all, :rest_for_one
  # that appear as literal values or atom operands.
  defp detect_strategy(instrs) do
    Enum.find_value(instrs, :unknown, fn
      {:move, {:atom, atom}, _} when atom in @strategies -> atom
      {:move, {:literal, kw}, _} when is_list(kw) -> Keyword.get(kw, :strategy)
      {:put_tuple2, _, {:list, elements}} -> find_strategy_in_elements(elements)
      {:put_map_assoc, _, _, _, _, {:list, pairs}} -> find_strategy_in_pairs(pairs)
      {:put_map_exact, _, _, _, _, {:list, pairs}} -> find_strategy_in_pairs(pairs)
      _ -> nil
    end)
  end

  defp find_strategy_in_elements(elements) do
    Enum.find_value(elements, nil, fn
      {:atom, atom} when atom in @strategies -> atom
      _ -> nil
    end)
  end

  defp find_strategy_in_pairs(pairs) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.find_value(nil, fn
      [{:atom, :strategy}, {:atom, strategy}] when strategy in @strategies -> strategy
      _ -> nil
    end)
  end

  # Extract child modules from literal values in init/1.
  # Child specs appear as literals like {Module, args} or %{id: ..., start: {Mod, ...}}.
  defp extract_children(instrs) do
    instrs
    |> Enum.flat_map(fn
      {:move, {:literal, val}, _} -> extract_child_from_literal(val)
      {:put_tuple2, _, {:list, elements}} -> extract_child_from_tuple_elements(elements)
      _ -> []
    end)
    |> Enum.uniq_by(fn {mod, _, _} -> mod end)
  end

  defp extract_child_from_literal(list) when is_list(list) do
    Enum.flat_map(list, &extract_single_child_spec/1)
  end

  defp extract_child_from_literal(val) do
    extract_single_child_spec(val)
  end

  # Child spec formats:
  # {Module, args} — shorthand
  # %{id: _, start: {Mod, :start_link, args}, restart: _, type: _} — full map
  # Module — bare module name (uses Module.child_spec/1)
  defp extract_single_child_spec({mod, _args}) when is_atom(mod) do
    [{mod, :permanent, :worker}]
  end

  defp extract_single_child_spec(%{start: {mod, _, _}} = spec) when is_atom(mod) do
    restart = Map.get(spec, :restart, :permanent)
    type = Map.get(spec, :type, :worker)
    [{mod, restart, type}]
  end

  defp extract_single_child_spec(mod) when is_atom(mod) do
    [{mod, :permanent, :worker}]
  end

  defp extract_single_child_spec(_), do: []

  defp extract_child_from_tuple_elements(elements) do
    # Look for module atoms in tuple construction that look like child specs.
    modules =
      Enum.filter(elements, fn
        {:atom, mod} when is_atom(mod) -> Code.ensure_loaded?(mod)
        _ -> false
      end)

    case modules do
      [{:atom, mod} | _] -> [{mod, :permanent, :worker}]
      _ -> []
    end
  end

  defp add_fact(facts, relation, row) do
    Map.update(facts, relation, [row], &[row | &1])
  end
end
