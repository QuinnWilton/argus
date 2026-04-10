defmodule Argus.Extractors.Supervision do
  @moduledoc """
  Supervision tree extractor.

  Analyzes modules that implement the `Supervisor` or `Application`
  behaviour to extract child specifications, restart strategies, and
  supervision structure.

  ## Approach

  Reads the module's attributes to detect `@behaviour Supervisor` or
  `use Application`. For supervisors, inspects `init/1`; for application
  modules, inspects `start/2`. Both paths scan the function's literal
  table for child spec data. Since child specs are often built at compile
  time and stored in the literal table, we can extract them without full
  dataflow analysis.

  ## Emitted facts

  - `supervisor(mod, strategy)` — module is a supervisor with given strategy
  - `supervisor_child(sup, position, child_mod, restart, type)` — child spec
  - `named_process(mod, name)` — named process registration detected
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      find_function: 3,
      get_behaviours: 1,
      match_local_call: 1,
      match_remote_call: 1,
      resolve_register: 3,
      scan_remote_calls: 4
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    mod_str = inspect(mod)
    attrs = module_data.attributes

    behaviours = get_behaviours(attrs)

    base_facts =
      cond do
        Supervisor in behaviours or :supervisor in behaviours ->
          extract_supervisor(mod_str, module_data)

        Application in behaviours or :application in behaviours ->
          extract_application(mod_str, module_data)

        true ->
          %{}
      end

    # DynamicSupervisor.start_child can fire from any module, regardless of
    # whether the enclosing module is itself a supervisor — connection pools
    # and per-tenant systems often spawn workers from non-supervisor code.
    extract_dynamic_children(base_facts, mod, module_data.functions)
  end

  defp extract_dynamic_children(facts, mod, functions) do
    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_dynamic_start(acc, ctx, mfa)
    end)
  end

  defp handle_dynamic_start(facts, ctx, {DynamicSupervisor, :start_child, 2}) do
    sup = resolve_atom_or_dynamic(ctx.instrs, ctx.idx, {:x, 0})
    child = resolve_dynamic_child_module(ctx.instrs, ctx.idx)

    if child == "dynamic" do
      facts
    else
      add_fact(facts, :dynamic_child, [sup, child, ctx.func_id])
    end
  end

  defp handle_dynamic_start(facts, _ctx, _mfa), do: facts

  defp resolve_atom_or_dynamic(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
    end
  end

  # The child argument to DynamicSupervisor.start_child can be:
  #   - A bare module atom: `DynamicSupervisor.start_child(sup, MyWorker)`
  #   - A 2-tuple: `DynamicSupervisor.start_child(sup, {MyWorker, args})`
  #   - A child spec map: `%{id: _, start: {MyWorker, :start_link, [args]}}`
  # We try each shape; failure is "dynamic".
  defp resolve_dynamic_child_module(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 1}) do
      {:ok, mod} when is_atom(mod) ->
        if module_atom?(mod), do: inspect(mod), else: "dynamic"

      {:ok, {mod, _args}} when is_atom(mod) ->
        if module_atom?(mod), do: inspect(mod), else: "dynamic"

      {:ok, %{start: {mod, _, _}}} when is_atom(mod) ->
        inspect(mod)

      _ ->
        "dynamic"
    end
  end

  defp module_atom?(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> true
      _ -> false
    end
  end

  defp extract_supervisor(mod_str, module_data) do
    case find_function(module_data.functions, :init, 1) do
      nil ->
        # Supervisor without init/1 — just record the behaviour.
        add_fact(%{}, :supervisor, [mod_str, "unknown"])

      instrs ->
        extract_from_instructions(%{}, mod_str, instrs, module_data.functions)
    end
  end

  defp extract_application(mod_str, module_data) do
    case find_function(module_data.functions, :start, 2) do
      nil -> %{}
      instrs -> extract_from_instructions(%{}, mod_str, instrs, module_data.functions)
    end
  end

  defp extract_from_instructions(facts, mod_str, instrs, all_functions) do
    strategy = detect_strategy(instrs)
    facts = add_fact(facts, :supervisor, [mod_str, to_string(strategy)])

    children = extract_children_with_helpers(instrs, all_functions)

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

  # Extract children from the given instructions, then follow local calls
  # one level deep to find children in helper functions. This catches the
  # common pattern where init/1 delegates to *_children helper functions
  # that return child spec lists.
  defp extract_children_with_helpers(instrs, all_functions) do
    direct = extract_children(instrs)

    from_helpers =
      Enum.flat_map(instrs, fn instr ->
        case match_local_call(instr) do
          {:ok, _mod, func, arity} ->
            case find_function(all_functions, func, arity) do
              nil -> []
              helper_instrs -> extract_children(helper_instrs)
            end

          :none ->
            []
        end
      end)

    (direct ++ from_helpers)
    |> Enum.uniq_by(fn {mod, _, _} -> mod end)
  end

  # Detect the supervision strategy by finding the Supervisor.init/2 or
  # Supervisor.start_link/2 call and resolving the options argument.
  # Falls back to scanning literals for Erlang-style {:ok, {flags, _}} returns.
  defp detect_strategy(instrs) do
    from_call =
      instrs
      |> Enum.with_index()
      |> Enum.find_value(fn {instr, idx} ->
        case match_remote_call(instr) do
          {:ok, Supervisor, func, 2} when func in [:init, :start_link] ->
            extract_strategy_from_opts(instrs, idx)

          _ ->
            nil
        end
      end)

    from_call || extract_strategy_from_literals(instrs) || :unknown
  end

  defp extract_strategy_from_opts(instrs, call_idx) do
    case resolve_register(instrs, call_idx, {:x, 1}) do
      {:ok, opts} when is_list(opts) -> Keyword.get(opts, :strategy)
      {:ok, opts} when is_map(opts) -> Map.get(opts, :strategy)
      _ -> nil
    end
  end

  # Scan literals for Erlang-style {:ok, {flags, children}} return values
  # and extract the strategy from the flags.
  defp extract_strategy_from_literals(instrs) do
    Enum.find_value(instrs, fn
      {:move, {:literal, {:ok, {flags, children}}}, _} when is_list(children) ->
        extract_strategy_from_flags(flags)

      # Erlang-style flags tuple may appear as a standalone move literal
      # or as an element inside a put_tuple2 when the full {:ok, {flags, children}}
      # can't be folded due to runtime children.
      {:move, {:literal, {strategy, intensity, period}}, _}
      when strategy in [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one] and
             is_integer(intensity) and is_integer(period) ->
        strategy

      {:put_tuple2, _, {:list, elements}} ->
        extract_strategy_from_elements(elements)

      _ ->
        nil
    end)
  end

  defp extract_strategy_from_elements(elements) do
    Enum.find_value(elements, fn
      {:literal, {strategy, intensity, period}}
      when strategy in [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one] and
             is_integer(intensity) and is_integer(period) ->
        strategy

      _ ->
        nil
    end)
  end

  defp extract_strategy_from_flags(flags) when is_map(flags), do: Map.get(flags, :strategy)
  defp extract_strategy_from_flags({strategy, _intensity, _period}), do: strategy
  defp extract_strategy_from_flags(_), do: nil

  # Extract child modules from literal values and tuple construction.
  # Child specs appear as literals like {Module, args} or %{id: ..., start: {Mod, ...}}.
  # When children are constructed at runtime, the compiler emits put_tuple2
  # instructions in reverse order (lists are built tail-first via cons cells).
  defp extract_children(instrs) do
    from_literals =
      Enum.flat_map(instrs, fn
        {:move, {:literal, val}, _} -> extract_child_from_literal(val)
        _ -> []
      end)

    # Map-based child specs: Erlang supervisors (and some Elixir ones) build
    # child spec maps at runtime via put_map_assoc/put_map_exact when the args
    # contain runtime values. We identify these by the presence of a :start key.
    from_maps =
      instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{op, _, _, _, _, {:list, pairs}}, idx}
        when op in [:put_map_assoc, :put_map_exact] ->
          extract_child_from_map_pairs(pairs, instrs, idx)

        _ ->
          []
      end)

    from_tuples =
      instrs
      |> Enum.flat_map(fn
        {:put_tuple2, _, {:list, elements}} -> extract_child_from_tuple_elements(elements)
        _ -> []
      end)
      |> Enum.reverse()

    (from_literals ++ from_maps ++ from_tuples)
    |> Enum.uniq_by(fn {mod, _, _} -> mod end)
  end

  # Check if a put_map instruction's pairs represent a child spec (has :start key),
  # resolve the start module, and extract :restart/:type metadata.
  defp extract_child_from_map_pairs(pairs, instrs, idx) do
    case find_map_pair(pairs, :start) do
      nil ->
        []

      start_val ->
        case resolve_start_module(start_val, instrs, idx) do
          nil ->
            []

          mod ->
            restart = extract_map_atom(pairs, :restart, :permanent)
            type = extract_map_atom(pairs, :type, :worker)
            [{mod, restart, type}]
        end
    end
  end

  # Find a value by atom key in a flat alternating [key, val, ...] pair list.
  defp find_map_pair(pairs, key) do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.find_value(fn
      [{:atom, ^key}, val] -> val
      _ -> nil
    end)
  end

  # Resolve the start module from a child spec map's :start value.
  # The value may be a literal tuple, a bare atom, or a register.
  defp resolve_start_module({:literal, {mod, _, _}}, _instrs, _idx) when is_atom(mod), do: mod
  defp resolve_start_module({:literal, {mod, _}}, _instrs, _idx) when is_atom(mod), do: mod
  defp resolve_start_module({:atom, mod}, _instrs, _idx) when is_atom(mod), do: mod

  defp resolve_start_module({:tr, inner, _}, instrs, idx),
    do: resolve_start_module_reg(inner, instrs, idx)

  defp resolve_start_module({kind, _} = reg, instrs, idx) when kind in [:x, :y],
    do: resolve_start_module_reg(reg, instrs, idx)

  defp resolve_start_module(_, _, _), do: nil

  defp resolve_start_module_reg(reg, instrs, idx) do
    case resolve_register(instrs, idx, reg) do
      {:ok, {mod, _, _}} when is_atom(mod) -> mod
      {:ok, {mod, _}} when is_atom(mod) -> mod
      _ -> nil
    end
  end

  # Extract an atom value from a flat pair list, with a default.
  defp extract_map_atom(pairs, key, default) do
    case find_map_pair(pairs, key) do
      {:atom, val} -> val
      _ -> default
    end
  end

  defp extract_child_from_literal(list) when is_list(list) do
    Enum.flat_map(list, &extract_single_child_spec/1)
  end

  # Erlang-style supervisor init returns {:ok, {flags, children}}.
  defp extract_child_from_literal({:ok, {_flags, children}}) when is_list(children) do
    extract_child_from_literal(children)
  end

  defp extract_child_from_literal(val) do
    extract_single_child_spec(val)
  end

  # Child spec formats:
  # {Module, args} — shorthand
  # %{id: _, start: {Mod, :start_link, args}, restart: _, type: _} — full map
  # Module — bare module name (uses Module.child_spec/1)
  #
  # Keyword pairs like {:strategy, :one_for_one} also match {atom, value},
  # so we filter with module_name?/1 to reject non-module atoms.
  defp extract_single_child_spec({mod, _args}) when is_atom(mod) do
    if module_name?(mod), do: [{mod, :permanent, :worker}], else: []
  end

  defp extract_single_child_spec(%{start: {mod, _, _}} = spec) when is_atom(mod) do
    restart = Map.get(spec, :restart, :permanent)
    type = Map.get(spec, :type, :worker)
    [{mod, restart, type}]
  end

  defp extract_single_child_spec(mod) when is_atom(mod) do
    if module_name?(mod), do: [{mod, :permanent, :worker}], else: []
  end

  defp extract_single_child_spec(_), do: []

  # Elixir modules are atoms starting with "Elixir." internally.
  # Erlang modules are lowercase atoms — accept those only if loadable.
  defp module_name?(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> true
      _ -> Code.ensure_loaded?(atom)
    end
  end

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
end
