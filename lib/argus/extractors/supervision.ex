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

  - `supervisor(mod, strategy, site)` — module is a supervisor with given
    strategy; `site` is the instruction ID of the call (or literal) that
    defines the tree — the strategy line — or `"dynamic"` when no such
    instruction was found
  - `supervisor_child(sup, position, child_mod, restart, type)` — child spec
  - `named_process(mod, name)` — named process registration detected
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      call_result_origin: 3,
      find_function: 3,
      get_behaviours: 1,
      keyword_value_register: 4,
      match_local_call: 1,
      match_remote_call: 1,
      resolve_register: 3,
      scan_remote_calls: 4,
      track_dynamic: 5,
      track_imprecision: 5
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

        # A `use DynamicSupervisor` module is a supervisor whose children are
        # all runtime-spawned — no static child specs, but it IS a supervisor
        # node, and its own `start_child` helpers target it (see the
        # self-anchor path below), so recording it lets those children attach.
        DynamicSupervisor in behaviours ->
          extract_dynamic_supervisor(mod_str, module_data)

        true ->
          %{}
      end

    # DynamicSupervisor.start_child can fire from any module, regardless of
    # whether the enclosing module is itself a supervisor — connection pools
    # and per-tenant systems often spawn workers from non-supervisor code.
    extract_dynamic_children(base_facts, mod, behaviours, module_data.functions)
  end

  defp extract_dynamic_children(facts, mod, behaviours, functions) do
    # When the `start_child` supervisor argument can't be resolved to an atom
    # but the enclosing module is itself a supervisor, the call almost always
    # targets that supervisor (the idiomatic `def start_x(sup, ...), do:
    # DynamicSupervisor.start_child(sup, ...)` helper on a `use
    # DynamicSupervisor` module). Anchor to self in that case rather than
    # dropping the child to "dynamic".
    self_sup = if supervisor_behaviour?(behaviours), do: inspect(mod), else: nil

    scan_remote_calls(mod, functions, facts, fn acc, ctx, mfa ->
      handle_dynamic_start(acc, ctx, mfa, self_sup, functions)
    end)
  end

  defp supervisor_behaviour?(behaviours) do
    Enum.any?(behaviours, &(&1 in [Supervisor, :supervisor, DynamicSupervisor]))
  end

  defp handle_dynamic_start(facts, ctx, {DynamicSupervisor, :start_child, 2}, self_sup, functions) do
    sup = resolve_start_child_sup(ctx.instrs, ctx.idx, self_sup, functions)
    child = resolve_dynamic_child_module(ctx.instrs, ctx.idx)

    if child == "dynamic" do
      # We can't extract a useful row, but we still want coverage to know
      # the call site existed. Reason :skipped distinguishes this from
      # the "we emitted a row but the field was dynamic" case.
      track_imprecision(facts, ctx, :dynamic_supervisor_child, :dynamic_child, :skipped)
    else
      facts
      |> track_dynamic(sup, ctx, :dynamic_supervisor_parent, :dynamic_child)
      |> add_fact(:dynamic_child, [sup, child, ctx.func_id])
    end
  end

  defp handle_dynamic_start(facts, _ctx, _mfa, _self_sup, _functions), do: facts

  # The supervisor argument to `start_child` is a registered name, a pid, or
  # a variable. A resolved atom (name or module) becomes the parent; a
  # `{:via, Registry, _}` tuple built by a `*.Registry.via(name, role)`
  # helper resolves to that via registration name (so it anchors to the
  # child registered under the same role); an unresolved argument falls back
  # to the enclosing supervisor module when there is one (`self_sup`), else
  # the honest "dynamic" sentinel.
  defp resolve_start_child_sup(instrs, idx, self_sup, functions) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) ->
        inspect(atom)

      _ ->
        resolve_via_name(instrs, idx, {:x, 0}, functions) || self_sup || "dynamic"
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

  # Registry via-tuple registration names.
  #
  # Libraries register dynamic children under `{:via, Registry, {mod, key}}`
  # tuples built by a `<Something>.Registry.via(name, role)` helper (Oban's
  # `Registry.via(conf.name, Foreman)`, and the like). The registry *name*
  # is a runtime value, but the *role* — the second argument — is a
  # compile-time literal shared between the child that registers under the
  # via and the `start_child` that targets it. Anchoring on that role lets
  # a dynamically-started supervisor nest under the DynamicSupervisor that
  # holds it, instead of floating unanchored.
  #
  # CAVEAT: the runtime registry name is dropped, so two instances of the
  # same library share a role — a deliberate over-approximation (correct
  # for the common single-instance case).
  #
  # `resolve_via_name` traces `register` to the via call — directly, or
  # through one level of local helper (`defp foreman(conf), do:
  # Registry.via(conf.name, Foreman)`) — and returns the name string, or nil.
  defp resolve_via_name(instrs, idx, register, functions) do
    case call_result_origin(instrs, idx, register) do
      {:ok, {mod, :via, arity}, origin_idx} when arity in [2, 3] ->
        if via_registry_module?(mod), do: via_role_name(instrs, origin_idx, mod)

      {:ok, {_mod, func, arity}, _origin_idx} ->
        # A local helper produced the value — resolve the via it returns.
        case find_function(functions, func, arity) do
          nil -> nil
          helper_instrs -> via_name_in_function(helper_instrs)
        end

      :no ->
        nil
    end
  end

  # A `via/2`|`via/3` on a `*.Registry` module builds a registry via-tuple.
  defp via_registry_module?(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> rest -> rest == "Registry" or String.ends_with?(rest, ".Registry")
      _ -> false
    end
  end

  # The role is the second argument (x1) at the via call site.
  defp via_role_name(instrs, via_idx, mod) do
    case resolve_register(instrs, via_idx, {:x, 1}) do
      {:ok, role} -> via_name(mod, role)
      _ -> nil
    end
  end

  # Scan a helper function for the registry via-call it returns, and name it.
  defp via_name_in_function(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.find_value(fn {instr, idx} ->
      case match_remote_call(instr) do
        {:ok, mod, :via, arity} when arity in [2, 3] ->
          if via_registry_module?(mod), do: via_role_name(instrs, idx, mod)

        _ ->
          nil
      end
    end)
  end

  # A stable, human-readable registration name: `Oban.Registry.via(Foreman)`.
  # Identical on both the registration and the `start_child` sides, so they
  # match; distinct per role, so siblings stay distinct.
  defp via_name(mod, role), do: "#{inspect(mod)}.via(#{inspect(role)})"

  defp extract_supervisor(mod_str, module_data) do
    case find_function(module_data.functions, :init, 1) do
      nil ->
        # Supervisor without init/1 — just record the behaviour.
        # The "unknown" strategy is a coverage gap worth surfacing.
        %{}
        |> track_imprecision(
          synthetic_ctx(mod_str, "init/1"),
          :supervisor_strategy,
          :supervisor,
          :missing
        )
        |> add_fact(:supervisor, [mod_str, "unknown"])
        |> add_fact(:supervisor_site, [mod_str, "dynamic"])

      instrs ->
        extract_from_instructions(%{}, mod_str, "init/1", instrs, module_data.functions)
    end
  end

  defp extract_application(mod_str, module_data) do
    case find_function(module_data.functions, :start, 2) do
      nil -> %{}
      instrs -> extract_from_instructions(%{}, mod_str, "start/2", instrs, module_data.functions)
    end
  end

  # A `use DynamicSupervisor` module has no static child specs — every child
  # is spawned via `start_child` at runtime — so we record the supervisor
  # node and its strategy but no `supervisor_child` rows. `DynamicSupervisor`
  # only supports `:one_for_one`, so that is the honest default when
  # `init/1` can't be read.
  defp extract_dynamic_supervisor(mod_str, module_data) do
    {strategy, site, max_children} =
      case find_function(module_data.functions, :init, 1) do
        nil -> {:one_for_one, "dynamic", nil}
        instrs -> detect_dynamic_strategy(mod_str, instrs)
      end

    %{}
    |> add_fact(:supervisor, [mod_str, to_string(strategy)])
    |> add_fact(:supervisor_site, [mod_str, site])
    |> emit_max_children(mod_str, max_children)
  end

  # Emitted only when a cap is actually set, so consumers ask about it by
  # negation. `DynamicSupervisor` defaults to `:infinity`, and the default is
  # what every project in the corpus uses — recording "unbounded" explicitly
  # would be a row per supervisor saying nothing.
  defp emit_max_children(facts, _mod_str, nil), do: facts
  defp emit_max_children(facts, _mod_str, :infinity), do: facts

  defp emit_max_children(facts, mod_str, value),
    do: add_fact(facts, :supervisor_max_children, [mod_str, to_string(value)])

  # DynamicSupervisor.init/1 takes the flags as its sole argument:
  # `DynamicSupervisor.init(strategy: :one_for_one, ...)`. Resolve that
  # options list; fall back to :one_for_one (the only strategy the behaviour
  # accepts) when it can't be read.
  defp detect_dynamic_strategy(mod_str, instrs) do
    strategy_idx =
      instrs
      |> Enum.with_index()
      |> Enum.find_value(fn {instr, idx} ->
        case match_remote_call(instr) do
          {:ok, DynamicSupervisor, :init, 1} ->
            case resolve_register(instrs, idx, {:x, 0}) do
              {:ok, opts} when is_list(opts) ->
                {Keyword.get(opts, :strategy, :one_for_one), idx,
                 Keyword.get(opts, :max_children)}

              _ ->
                {:one_for_one, idx, nil}
            end

          _ ->
            nil
        end
      end)

    case strategy_idx do
      {strategy, idx, max_children} -> {strategy, "#{mod_str}:init/1##{idx}", max_children}
      nil -> {:one_for_one, "dynamic", nil}
    end
  end

  defp extract_from_instructions(facts, mod_str, func_label, instrs, all_functions) do
    {strategy, site} = detect_strategy(mod_str, func_label, instrs)

    facts =
      facts
      |> add_fact(:supervisor, [mod_str, to_string(strategy)])
      |> add_fact(:supervisor_site, [mod_str, site])

    children = extract_children_with_helpers(instrs, all_functions)

    facts =
      if children == [] do
        # init/1 was found but no static child specs were extracted —
        # the children might be runtime-built (Enum.map, comprehensions)
        # or use a shape we don't recognize. Mark as a skipped extraction.
        track_imprecision(
          facts,
          synthetic_ctx(mod_str, "init/1"),
          :supervisor_child_module,
          :supervisor_child,
          :missing
        )
      else
        facts
      end

    children
    |> Enum.with_index()
    |> Enum.reduce(facts, fn {{child_mod, restart, type, name, form}, idx}, acc ->
      acc =
        acc
        |> add_fact(:supervisor_child, [
          mod_str,
          to_string(idx),
          inspect(child_mod),
          to_string(restart),
          to_string(type)
        ])
        |> add_fact(:supervisor_child_form, [mod_str, to_string(idx), to_string(form)])

      # A registered `:name` rides alongside the child at the same position,
      # so a name-keyed `start_child` can later anchor to this exact child.
      if name do
        add_fact(acc, :supervisor_child_name, [mod_str, to_string(idx), name])
      else
        acc
      end
    end)
  end

  # The literal child-spec scanners don't run inside scan_functions and
  # therefore don't have a real instruction context. Build a synthetic ctx
  # naming the supervisor's init/1 (or start/2) so coverage events can
  # still be attributed to a function.
  defp synthetic_ctx(mod_str, func_label) do
    %{func_id: InstrId.func_id(mod_str, func_label), instrs: [], idx: 0}
  end

  # Extract children from the given instructions, then follow local calls
  # one level deep to find children in helper functions. This catches the
  # common pattern where init/1 delegates to *_children helper functions
  # that return child spec lists.
  defp extract_children_with_helpers(instrs, all_functions) do
    direct = extract_children(instrs, all_functions)

    from_helpers =
      Enum.flat_map(instrs, fn instr ->
        case match_local_call(instr) do
          {:ok, _mod, func, arity} ->
            case find_function(all_functions, func, arity) do
              nil -> []
              helper_instrs -> extract_children(helper_instrs, all_functions)
            end

          :none ->
            []
        end
      end)

    (direct ++ from_helpers)
    |> Enum.uniq_by(fn {mod, _, _, name, _form} -> {mod, name} end)
  end

  # Detect the supervision strategy by finding the Supervisor.init/2 or
  # Supervisor.start_link/2 call and resolving the options argument.
  # Falls back to scanning literals for Erlang-style {:ok, {flags, _}} returns.
  #
  # Returns `{strategy, site}` where `site` is the instruction ID of the
  # detection point — the line that defines the tree, so findings about
  # the supervisor's composition can anchor where the fix goes. Instruction
  # indexes here match Layer-1 IDs because `Normalize`, the extractor
  # helpers, and this scan all number the same raw instruction list.
  defp detect_strategy(mod_str, func_label, instrs) do
    case detect_strategy_call(instrs) || detect_strategy_literal(instrs) do
      {strategy, idx} -> {strategy, InstrId.mint(InstrId.func_id(mod_str, func_label), idx)}
      nil -> {:unknown, "dynamic"}
    end
  end

  defp detect_strategy_call(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.find_value(fn {instr, idx} ->
      case match_remote_call(instr) do
        {:ok, Supervisor, func, 2} when func in [:init, :start_link] ->
          case extract_strategy_from_opts(instrs, idx) do
            nil -> nil
            strategy -> {strategy, idx}
          end

        _ ->
          nil
      end
    end)
  end

  defp extract_strategy_from_opts(instrs, call_idx) do
    case resolve_register(instrs, call_idx, {:x, 1}) do
      {:ok, opts} when is_list(opts) -> Keyword.get(opts, :strategy)
      {:ok, opts} when is_map(opts) -> Map.get(opts, :strategy)
      _ -> nil
    end
  end

  # Scan literals for Erlang-style {:ok, {flags, children}} return values
  # and extract the strategy (and its defining instruction) from the flags.
  defp detect_strategy_literal(instrs) do
    instrs
    |> Enum.with_index()
    |> Enum.find_value(fn {instr, idx} ->
      case strategy_from_literal_instr(instr) do
        nil -> nil
        strategy -> {strategy, idx}
      end
    end)
  end

  defp strategy_from_literal_instr(instr) do
    case instr do
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
    end
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
  defp extract_children(instrs, functions) do
    from_literals =
      Enum.flat_map(instrs, fn
        {:move, {:literal, val}, _} -> extract_child_from_literal(val)
        _ -> []
      end)

    # A single runtime element (a tuple whose options call out at
    # runtime — the stock Phoenix Application shape) splits the list
    # into cons cells: literal specs survive as put_list operands (bare
    # module heads, a literal tail carrying the rest), never reaching a
    # move-literal. Reverse instruction order approximates source order
    # (lists are built tail-first), though elements interleaved with
    # runtime construction can land out of position — membership over
    # perfect ordering.
    from_cons =
      instrs
      |> Enum.reverse()
      |> Enum.flat_map(fn
        {:put_list, head, tail, _dst} ->
          extract_child_from_cons_operand(head) ++ extract_child_from_cons_tail(tail)

        _ ->
          []
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
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:put_tuple2, _, {:list, elements}}, idx} ->
          extract_child_from_tuple_elements(elements, instrs, idx, functions)

        _ ->
          []
      end)
      |> Enum.reverse()

    # Dedup by {module, registered name}: two children of the same module
    # are distinct when they register under different names (three
    # `{DynamicSupervisor, name: ...}` children are three supervisors, not
    # one). Same module and same name (or both nameless) still collapse —
    # without a distinguishing name there is nothing to tell them apart.
    (from_literals ++ from_cons ++ from_maps ++ from_tuples)
    |> Enum.uniq_by(fn {mod, _, _, name, _form} -> {mod, name} end)
  end

  defp extract_child_from_cons_operand({:atom, mod}) when is_atom(mod) do
    if module_name?(mod), do: [{mod, :permanent, :worker, nil, :shorthand}], else: []
  end

  defp extract_child_from_cons_operand({:literal, val}), do: extract_single_child_spec(val)
  defp extract_child_from_cons_operand(_), do: []

  defp extract_child_from_cons_tail({:literal, list}) when is_list(list) do
    extract_child_from_literal(list)
  end

  defp extract_child_from_cons_tail(_), do: []

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
            # A map spec's registered name lives inside its :start MFA args,
            # too deep to read reliably here — leave it unrecorded.
            form = if find_map_pair(pairs, :type), do: :explicit, else: :shorthand
            [{mod, restart, type, nil, form}]
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
  # {PartitionSupervisor, opts} — wrapper that replicates :child_spec across partitions
  # %{id: _, start: {Mod, :start_link, args}, restart: _, type: _} — full map
  # Module — bare module name (uses Module.child_spec/1)
  #
  # Keyword pairs like {:strategy, :one_for_one} also match {atom, value},
  # so we filter with module_name?/1 to reject non-module atoms.
  defp extract_single_child_spec({PartitionSupervisor, opts}) when is_list(opts) do
    # PartitionSupervisor is a wrapper — extract the underlying child_spec
    # so analyses see the real worker module instead of PartitionSupervisor.
    case Keyword.get(opts, :child_spec) do
      nil -> [{PartitionSupervisor, :permanent, :supervisor, child_name(opts), :explicit}]
      child_spec -> extract_single_child_spec(child_spec)
    end
  end

  # The shorthand states neither restart nor type — `Module.child_spec/1`
  # does, and `use Supervisor` generates `type: :supervisor` while
  # `use GenServer` generates `type: :worker`. The values below are
  # DEFAULTS, and `supervisor_child_form` records that so consumers can
  # resolve the type from the child's own behaviour instead of trusting a
  # guess. `:permanent` happens to be right either way; `:worker` is wrong
  # for every supervisor written this way.
  defp extract_single_child_spec({mod, args}) when is_atom(mod) do
    if module_name?(mod), do: [{mod, :permanent, :worker, child_name(args), :shorthand}], else: []
  end

  defp extract_single_child_spec(%{start: {mod, _, _}} = spec) when is_atom(mod) do
    restart = Map.get(spec, :restart, :permanent)
    type = Map.get(spec, :type, :worker)
    form = if Map.has_key?(spec, :type), do: :explicit, else: :shorthand
    [{mod, restart, type, nil, form}]
  end

  defp extract_single_child_spec(mod) when is_atom(mod) do
    if module_name?(mod), do: [{mod, :permanent, :worker, nil, :shorthand}], else: []
  end

  defp extract_single_child_spec(_), do: []

  # A child spec's `:name` option registers the process under a name — the
  # same name a `DynamicSupervisor.start_child(name, _)` call later targets.
  # Only atoms are name-anchorable; `{:via, _, _}`/`{:global, _}` names are
  # skipped. The scan tolerates non-keyword option lists (mixed positional
  # args) by matching `{:name, atom}` pairs directly.
  defp child_name(opts) when is_list(opts) do
    Enum.find_value(opts, fn
      {:name, name} when is_atom(name) and not is_nil(name) -> inspect(name)
      _ -> nil
    end)
  end

  defp child_name(_), do: nil

  # Elixir modules are atoms starting with "Elixir." internally.
  # Erlang modules are lowercase atoms — accept those only if loadable.
  defp module_name?(atom) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> _ -> true
      _ -> Code.ensure_loaded?(atom)
    end
  end

  defp extract_child_from_tuple_elements(elements, instrs, idx, functions) do
    # Look for module atoms in tuple construction that look like child
    # specs. module_name?/1, not Code.ensure_loaded?/1: the analyzed
    # project's modules are rarely loadable in the analyzing VM, and an
    # Elixir-prefixed atom is a module name regardless.
    modules =
      Enum.filter(elements, fn
        {:atom, mod} when is_atom(mod) -> module_name?(mod)
        _ -> false
      end)

    case modules do
      # The `name:` is runtime-built, so a literal read finds nothing — but
      # a `{:via, Registry, _}` registration is still recoverable by tracing
      # the opts through its construction to the via call.
      [{:atom, mod} | _] ->
        [{mod, :permanent, :worker, via_child_name(elements, instrs, idx, functions), :shorthand}]

      _ ->
        []
    end
  end

  # The child spec's opts is a register operand of the same tuple; trace its
  # `:name` value back to a via registration.
  defp via_child_name(elements, instrs, idx, functions) do
    Enum.find_value(elements, fn
      {kind, _} = reg when kind in [:x, :y] ->
        via_name_from_opts(reg, instrs, idx, functions)

      {:tr, {kind, _} = reg, _} when kind in [:x, :y] ->
        via_name_from_opts(reg, instrs, idx, functions)

      _ ->
        nil
    end)
  end

  defp via_name_from_opts(opts_reg, instrs, idx, functions) do
    case keyword_value_register(instrs, idx, opts_reg, :name) do
      {:ok, name_reg, name_idx} -> resolve_via_name(instrs, name_idx, name_reg, functions)
      :no -> nil
    end
  end
end
