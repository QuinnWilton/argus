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
  - `child_spec_restart(mod, restart)` — the restart the module's own
    child_spec/1 declares
  - `post_start_call(func, site, callee)` — a call made after a
    Supervisor.start_link in the same function
  - `supervisor_child(sup, position, child_mod, restart, type)` — child spec
  - `supervisor_children_open(sup)` — the child list has an element or a
    tail this extractor cannot read: its children and positions are
    partial
  - `named_process(mod, name)` — named process registration detected
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.CallSites
  alias Argus.Extractor.Resolve
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Helpers,
    only: [
      each_remote_call: 3,
      find_function: 3,
      get_behaviours: 1,
      match_local_call: 1,
      match_remote_call: 1
    ]

  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 5]

  import Argus.Extractor.Resolve,
    only: [call_result_origin: 3, keyword_value_register: 4, resolve_register: 3]

  import Argus.Extractor.Terms, only: [list_elements: 1, mentions?: 2]

  # The restart and type an OTP child spec states: what tells its tuple
  # form from any other 6-tuple.
  @restarts [:permanent, :transient, :temporary]
  @child_types [:worker, :supervisor]

  # Behaviour modules a start function names when the child's own module
  # is among its arguments (`{gen_server, start_link, [{local, n}, Mod,
  # Args, Opts]}`).
  @starting_behaviours [GenServer, Supervisor, Agent, Task, :gen_server, :gen_statem, :supervisor]

  @impl true
  def relations,
    do: [
      :child_spec_restart,
      :post_start_call,
      :dynamic_child,
      :supervisor,
      :supervisor_child,
      :supervisor_children_open,
      :supervisor_child_form,
      :supervisor_child_name,
      :supervisor_max_children,
      :supervisor_site,
      :task_supervisor_start
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
        Supervisor in behaviours or :supervisor in behaviours or
            ConsumerSupervisor in behaviours ->
          extract_supervisor(mod_str, module_data)

        Application in behaviours or :application in behaviours ->
          extract_application(mod_str, module_data)

        # A `use DynamicSupervisor` module is a supervisor whose children are
        # all runtime-spawned — no static child specs, but it IS a supervisor
        # node, and its own `start_child` helpers target it (see the
        # self-anchor path below), so recording it lets those children attach.
        DynamicSupervisor in behaviours ->
          extract_dynamic_supervisor(mod_str, module_data)

        # A tree can be defined without the Supervisor behaviour: a
        # GenServer that starts a supervisor from its init/1 (Broadway's
        # Topology), a library's start_link/1 that assembles children and
        # calls Supervisor.start_link (Cachex). The function that makes the
        # Supervisor.start_link/init call is the tree definition.
        true ->
          case tree_function(module_data.functions) do
            nil ->
              %{}

            {label, instrs} ->
              extract_from_instructions(%{}, mod_str, label, instrs, module_data.functions)
          end
      end

    # DynamicSupervisor.start_child can fire from any module, regardless of
    # whether the enclosing module is itself a supervisor — connection pools
    # and per-tenant systems often spawn workers from non-supervisor code.
    base_facts
    |> extract_dynamic_children(mod, behaviours, module_data)
    |> extract_child_spec_restart(mod_str, module_data.functions)
    |> extract_post_start_calls(mod_str, module_data)
  end

  # The restart a module's own child_spec/1 declares — what a shorthand
  # `{Mod, args}` spec resolves to. `use GenServer, restart: :temporary`
  # puts it in the generated function's literal map.
  defp extract_child_spec_restart(facts, mod_str, functions) do
    case find_function(functions, :child_spec, 1) do
      nil ->
        facts

      instrs ->
        instrs
        |> Enum.flat_map(fn
          # A literal spec map: `%{id: .., start: .., restart: :temporary}`.
          {:move, {:literal, %{restart: restart}}, _} when is_atom(restart) ->
            [restart]

          # The overrides `use GenServer, restart: :temporary` passes to
          # Supervisor.child_spec/2.
          {:move, {:literal, overrides}, _} when is_list(overrides) ->
            case Keyword.keyword?(overrides) and Keyword.get(overrides, :restart) do
              restart when is_atom(restart) and not is_nil(restart) and restart != false ->
                [restart]

              _ ->
                []
            end

          {op, _, _, _, _, {:list, pairs}} when op in [:put_map_assoc, :put_map_exact] ->
            case extract_map_atom(pairs, :restart, nil) do
              nil -> []
              restart -> [restart]
            end

          _ ->
            []
        end)
        |> Enum.uniq()
        |> Enum.reduce(facts, fn restart, acc ->
          add_fact(acc, :child_spec_restart, [mod_str, to_string(restart)])
        end)
    end
  end

  # Every call made after a Supervisor.start_link in the same function:
  # the tree is running, so whatever these calls set up, a child may
  # already be reading.
  defp extract_post_start_calls(facts, _mod_str, module_data) do
    started =
      module_data
      |> CallSites.for_module()
      |> Enum.filter(fn site ->
        match?({_sup, :start_link, _}, site.mfa) and
          elem(site.mfa, 0) in [Supervisor, ConsumerSupervisor]
      end)
      |> Enum.group_by(& &1.func_id, & &1.idx)
      |> Map.new(fn {func_id, idxs} -> {func_id, Enum.min(idxs)} end)

    if started == %{} do
      facts
    else
      module_data
      |> CallSites.for_module()
      |> Enum.reduce(facts, fn site, acc ->
        case Map.get(started, site.func_id) do
          start_idx when is_integer(start_idx) and site.idx > start_idx ->
            {m, f, a} = site.mfa
            callee = Normalize.func_id(m, f, a)

            add_fact(acc, :post_start_call, [
              site.func_id,
              InstrId.mint(site.func_id, site.idx),
              callee
            ])

          _ ->
            acc
        end
      end)
    end
  end

  defp extract_dynamic_children(facts, mod, behaviours, module_data) do
    functions = module_data.functions
    # When the `start_child` supervisor argument can't be resolved to an atom
    # but the enclosing module is itself a supervisor, the call almost always
    # targets that supervisor (the idiomatic `def start_x(sup, ...), do:
    # DynamicSupervisor.start_child(sup, ...)` helper on a `use
    # DynamicSupervisor` module). Anchor to self in that case rather than
    # dropping the child to "dynamic".
    self_sup = if supervisor_behaviour?(behaviours), do: inspect(mod), else: nil

    each_remote_call(module_data, facts, fn acc, ctx, mfa ->
      handle_dynamic_start(acc, ctx, mfa, self_sup, functions)
    end)
  end

  # The first function calling Supervisor.start_link/2 or Supervisor.init/2,
  # as `{"name/arity", instrs}`.
  defp tree_function(functions) do
    Enum.find_value(functions, fn
      {:function, name, arity, _label, instrs} ->
        if Enum.any?(instrs, &supervisor_start_call?/1), do: {"#{name}/#{arity}", instrs}

      _ ->
        nil
    end)
  end

  # ConsumerSupervisor.init/2 takes the same children-and-options shape
  # as Supervisor.init/2; its children are a template, so their restart
  # matters more, not less.
  defp supervisor_start_call?(instr) do
    case match_remote_call(instr) do
      {:ok, sup, func, 2}
      when sup in [Supervisor, ConsumerSupervisor] and func in [:init, :start_link] ->
        true

      _ ->
        false
    end
  end

  defp supervisor_behaviour?(behaviours) do
    Enum.any?(
      behaviours,
      &(&1 in [Supervisor, :supervisor, DynamicSupervisor, ConsumerSupervisor])
    )
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

  # A task started under a Task.Supervisor is a dynamic child of that
  # supervisor as much as a worker under a DynamicSupervisor: it lives
  # in the supervisor's tree, not the starter's. The child is the
  # closure, recorded as "Task".
  @task_starts [:start_child, :async, :async_nolink, :async_stream, :async_stream_nolink]

  defp handle_dynamic_start(facts, ctx, {Task.Supervisor, fun, arity}, self_sup, functions)
       when fun in @task_starts and arity >= 2 do
    sup = resolve_start_child_sup(ctx.instrs, ctx.idx, self_sup, functions)

    facts
    |> track_dynamic(sup, ctx, :dynamic_supervisor_parent, :dynamic_child)
    |> add_fact(:dynamic_child, [sup, "Task", ctx.func_id])
    |> add_fact(:task_supervisor_start, [
      InstrId.mint(ctx.func_id, ctx.idx),
      ctx.func_id,
      to_string(fun)
    ])
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

      {:ok, {mod, func, arity}, _origin_idx} ->
        # A helper of this module produced the value — resolve the via it
        # returns. Another module's function's body is not in hand, and a
        # function here of the same name and arity is not it.
        with helper_instrs when helper_instrs != nil <- find_function(functions, func, arity),
             true <- defined_in?(helper_instrs, mod) do
          via_name_in_function(helper_instrs)
        else
          _ -> nil
        end

      :no ->
        nil
    end
  end

  defp defined_in?(instrs, mod),
    do: Enum.any?(instrs, &match?({:func_info, {:atom, ^mod}, _name, _arity}, &1))

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
    |> add_fact(:supervisor, [mod_str, word(strategy)])
    |> add_fact(:supervisor_site, [mod_str, site])
    |> emit_max_children(mod_str, max_children)
  end

  # A flag, restart or type read from a literal is an atom (a cap, an
  # integer); anything else there is a value the supervisor would reject,
  # and names nothing.
  defp word(value) when is_atom(value) or is_integer(value), do: to_string(value)
  defp word(_value), do: "dynamic"

  # Emitted only when a cap is actually set, so consumers ask about it by
  # negation. `DynamicSupervisor` defaults to `:infinity`, and the default is
  # what every project in the corpus uses — recording "unbounded" explicitly
  # would be a row per supervisor saying nothing.
  defp emit_max_children(facts, _mod_str, nil), do: facts
  defp emit_max_children(facts, _mod_str, :infinity), do: facts

  defp emit_max_children(facts, mod_str, value),
    do: add_fact(facts, :supervisor_max_children, [mod_str, word(value)])

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
      |> add_fact(:supervisor, [mod_str, word(strategy)])
      |> add_fact(:supervisor_site, [mod_str, site])

    {children, open?} =
      case child_list(instrs, all_functions) do
        {:closed, kids} -> {finish_children(kids), false}
        :open -> {extract_children_with_helpers(instrs, all_functions), true}
        :none -> {extract_children_with_helpers(instrs, all_functions), false}
      end

    facts = if open?, do: add_fact(facts, :supervisor_children_open, [mod_str]), else: facts

    facts =
      if children == [] do
        # The tree function was found but no static child specs were
        # extracted — the children use a shape we don't recognize. Mark
        # as a skipped extraction.
        track_imprecision(
          facts,
          synthetic_ctx(mod_str, func_label),
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
          word(restart),
          word(type)
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

  # ── The child list, read in order ──────────────────────────────────
  #
  # The list the tree function hands Supervisor.init/2 or
  # Supervisor.start_link/2 (or an Erlang init's `{ok, {Flags,
  # Children}}` return builds), read element by element, the way the VM
  # builds it: each cell's head, then what its tail held. `{:closed,
  # children}` in source order when every element is a spec this
  # extractor reads (a literal, a module, a `{Mod, args}` tuple, a map
  # with a `:start`, a `Supervisor.child_spec/2` of one) and the list ends
  # in a literal; `:open` when an element or the tail is computed: a list
  # appended from config, an `Enum.map`, a parameter, a spec from a call
  # it does not read. A local function returning the list is read through
  # its returns, one level. `:none` when no such list is found; the flat
  # scans below then read the children as before.
  #
  # An open list's children and positions are partial: a child the list
  # does not show may start after any it lists (supervisor_children_open).
  @list_depth 2

  defp child_list(instrs, functions) do
    case children_operand(instrs) do
      nil -> :none
      {idx, reg} -> read_list(instrs, idx, reg, functions, @list_depth)
    end
  end

  defp children_operand(instrs) do
    indexed = Enum.with_index(instrs)

    Enum.find_value(indexed, fn {instr, idx} ->
      case match_remote_call(instr) do
        {:ok, Supervisor, f, 2} when f in [:init, :start_link] -> {idx, {:x, 0}}
        _ -> nil
      end
    end) ||
      Enum.find_value(indexed, fn
        {{:put_tuple2, _dst, {:list, [{:atom, :ok}, inner]}}, idx} ->
          erlang_children(instrs, idx, inner)

        _ ->
          nil
      end)
  end

  # `{ok, {Flags, Children}}`: the children are the second element of the
  # tuple the `ok` tuple holds.
  defp erlang_children(instrs, idx, inner) do
    with reg when reg != nil <- element_register(inner),
         {at, children} <-
           Resolve.trace(instrs, idx, reg, nil, fn
             {at, {:put_tuple2, _dst, {:list, [_flags, children]}}}, _follow -> {at, children}
             _writer, _follow -> nil
           end) do
      case element_register(children) do
        nil -> nil
        reg -> {at, reg}
      end
    end
  end

  defp read_list(_instrs, _idx, _reg, _functions, depth) when depth < 0, do: :open

  defp read_list(instrs, idx, reg, functions, depth) do
    Resolve.trace(instrs, idx, reg, :open, fn
      {at, {:put_list, head, tail, _dst}}, _follow ->
        with {:ok, kids} <- read_head(instrs, at, head, functions),
             {:closed, rest} <- read_tail(instrs, at, tail, functions, depth) do
          {:closed, kids ++ rest}
        else
          _ -> :open
        end

      {at, {:move, operand, _dst}}, _follow ->
        read_tail(instrs, at, operand, functions, depth)

      {:param, _}, _follow ->
        :open

      {_at, instr}, _follow ->
        case match_local_call(instr) do
          {:ok, _mod, name, arity} -> read_returned_list(functions, name, arity, depth - 1)
          :none -> :open
        end
    end)
  end

  defp read_tail(_instrs, _idx, nil, _functions, _depth), do: {:closed, []}
  defp read_tail(_instrs, _idx, {:atom, nil}, _functions, _depth), do: {:closed, []}
  defp read_tail(_instrs, _idx, {:literal, list}, _functions, _depth), do: read_literal_list(list)

  defp read_tail(instrs, idx, operand, functions, depth) do
    case element_register(operand) do
      nil -> :open
      reg -> read_list(instrs, idx, reg, functions, depth)
    end
  end

  defp read_literal_list(list) when is_list(list) do
    specs = Enum.map(list_elements(list), &extract_single_child_spec/1)
    if Enum.any?(specs, &(&1 == [])), do: :open, else: {:closed, Enum.concat(specs)}
  end

  defp read_literal_list(_other), do: :open

  defp read_head(instrs, idx, operand, functions) do
    case operand do
      {:literal, value} ->
        spec_or_error(extract_single_child_spec(value))

      {:atom, _} ->
        spec_or_error(extract_child_from_cons_operand(operand))

      _ ->
        case element_register(operand) do
          nil -> :error
          reg -> read_head_register(instrs, idx, reg, functions)
        end
    end
  end

  defp read_head_register(instrs, idx, reg, functions) do
    Resolve.trace(instrs, idx, reg, :error, fn
      {at, {:put_tuple2, _dst, {:list, elements}}}, _follow ->
        spec_or_error(extract_child_from_tuple_elements(elements, instrs, at, functions))

      {at, {op, _, _, _, _, {:list, pairs}}}, _follow
      when op in [:put_map_assoc, :put_map_exact] ->
        spec_or_error(extract_child_from_map_pairs(pairs, instrs, at))

      {at, {:move, operand, _dst}}, _follow ->
        read_head(instrs, at, operand, functions)

      {:param, _}, _follow ->
        :error

      {at, instr}, _follow ->
        # Supervisor.child_spec/2 overrides a spec's fields; the module is
        # its first argument's.
        case match_remote_call(instr) do
          {:ok, Supervisor, :child_spec, 2} -> read_head(instrs, at, {:x, 0}, functions)
          _ -> :error
        end
    end)
  end

  defp spec_or_error([]), do: :error
  defp spec_or_error(specs), do: {:ok, specs}

  # A local function that returns the child list: the list each of its
  # returns hands back, when they agree.
  defp read_returned_list(_functions, _name, _arity, depth) when depth < 0, do: :open

  defp read_returned_list(functions, name, arity, depth) do
    with body when body != nil <- find_function(functions, name, arity),
         [_ | _] = returns <-
           for({:return, at} <- Enum.with_index(body), do: at) do
      lists = Enum.map(returns, &read_list(body, &1, {:x, 0}, functions, depth))

      case Enum.uniq(lists) do
        [{:closed, _} = one] -> one
        _ -> :open
      end
    else
      _ -> :open
    end
  end

  # What the flat scans' results go through: a spec naming only the
  # behaviour that starts it (`{GenServer, :start_link, [runtime_mod,
  # ...]}`) names no process module; the same module under the same
  # registered name is one child.
  defp finish_children(children) do
    children
    |> Enum.reject(fn {mod, _, _, _, _} ->
      mod in [GenServer, Agent, Task, :gen_server, :gen_statem]
    end)
    |> Enum.uniq_by(fn {mod, _, _, name, _form} -> {mod, name} end)
  end

  # The literal child-spec scanners don't run inside scan_functions and
  # therefore don't have a real instruction context. Build a synthetic ctx
  # naming the supervisor's init/1 (or start/2) so coverage events can
  # still be attributed to a function.
  defp synthetic_ctx(mod_str, func_label) do
    %{func_id: InstrId.func_id(mod_str, func_label), instrs: [], idx: 0}
  end

  # Extract children from the tree function, then from the helpers it
  # calls, breadth-first to a bounded depth. Helpers include closures the
  # function creates — `for`/`Enum.map` comprehension bodies are lifted
  # into their own functions, and that is where a spec built per element
  # (`for i <- 0..n, do: %{start: {Producer, ...}}`) actually lives.
  # Breadth-first order approximates construction order: a spec built by
  # a helper called from the tree function comes before one built by a
  # closure that helper creates.
  @helper_depth 3

  defp extract_children_with_helpers(instrs, all_functions) do
    by_label =
      Map.new(all_functions, fn {:function, name, arity, label, body} ->
        {label, {name, arity, body}}
      end)

    walk_helpers([instrs], all_functions, by_label, MapSet.new(), 0, [])
    |> Enum.uniq_by(fn {mod, _, _, name, _form} -> {mod, name} end)
  end

  defp walk_helpers([], _functions, _by_label, _seen, _depth, acc), do: acc

  defp walk_helpers(_frontier, _functions, _by_label, _seen, depth, acc)
       when depth > @helper_depth,
       do: acc

  defp walk_helpers(frontier, functions, by_label, seen, depth, acc) do
    # Tuple-shaped specs (`{Mod, args}`) are only trusted in the tree
    # function and its direct helpers: deeper down, a 2-tuple holding a
    # module atom is far more often a dispatcher option or a tagged value
    # than a child spec. Literal lists and map specs carry their own shape
    # and are trusted at any depth.
    found = Enum.flat_map(frontier, &extract_children(&1, functions, shallow?: depth <= 1))

    {next, seen} =
      Enum.reduce(frontier, {[], seen}, fn body, {next, seen} ->
        Enum.reduce(body, {next, seen}, fn instr, {next, seen} ->
          case helper_target(instr, functions, by_label) do
            {key, helper_body} ->
              if MapSet.member?(seen, key),
                do: {next, seen},
                else: {next ++ [helper_body], MapSet.put(seen, key)}

            nil ->
              {next, seen}
          end
        end)
      end)

    walk_helpers(next, functions, by_label, seen, depth + 1, acc ++ found)
  end

  defp helper_target(instr, functions, by_label) do
    case instr do
      {:make_fun3, {:f, label}, _index, _uniq, _dst, _env} ->
        case Map.get(by_label, label) do
          {name, arity, body} -> {{name, arity}, body}
          nil -> nil
        end

      {:make_fun3, {_mod, name, arity}, _index, _uniq, _dst, _env} ->
        case find_function(functions, name, arity) do
          nil -> nil
          body -> {{name, arity}, body}
        end

      _ ->
        case match_local_call(instr) do
          {:ok, _mod, func, arity} ->
            case find_function(functions, func, arity) do
              nil -> nil
              body -> {{func, arity}, body}
            end

          :none ->
            nil
        end
    end
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
        {:ok, sup, func, 2}
        when sup in [Supervisor, ConsumerSupervisor] and func in [:init, :start_link] ->
          case extract_strategy_from_opts(instrs, idx) || strategy_in_cons(instrs) do
            nil -> nil
            strategy -> {strategy, idx}
          end

        _ ->
          nil
      end
    end)
  end

  # Options assembled at runtime (`[name: name(config), strategy:
  # :rest_for_one]`) are cons cells, and the literal `strategy:` pair
  # survives as a put_list head. One tree per function, so the first
  # such pair in the function is the tree's.
  @strategies [:one_for_one, :one_for_all, :rest_for_one, :simple_one_for_one]

  defp strategy_in_cons(instrs) do
    Enum.find_value(instrs, fn
      {:put_list, {:literal, {:strategy, strategy}}, _tail, _dst} when strategy in @strategies ->
        strategy

      {:put_list, _head, {:literal, tail}, _dst} when is_list(tail) ->
        case Keyword.keyword?(tail) and Keyword.get(tail, :strategy) do
          strategy when strategy in @strategies -> strategy
          _ -> nil
        end

      _ ->
        nil
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
  defp extract_children(instrs, functions, opts) do
    from_literals =
      Enum.flat_map(instrs, fn
        {:move, {:literal, val}, _} -> extract_child_from_literal(val)
        _ -> []
      end)

    # A tuple is only a child spec if it goes somewhere a child spec goes:
    # into a list (a put_list head) or straight out of a spec helper (the
    # function returns it). `{GenStage.DemandDispatcher, opts}` built as
    # a producer option never does either.
    tuple_specs =
      instrs
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:put_tuple2, dst, {:list, elements}}, idx} ->
          if tuple_used_as_spec?(instrs, idx, dst),
            do: extract_child_from_tuple_elements(elements, instrs, idx, functions),
            else: []

        _ ->
          []
      end)
      |> Enum.reverse()

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

    shallow? = Keyword.get(opts, :shallow?, true)
    from_tuples = if shallow?, do: tuple_specs, else: []
    from_cons = if shallow?, do: from_cons, else: []

    # When the list is a cons chain, walk it from its outermost cell so
    # the children come out in source order; the flat scans above are
    # kept as the fallback for shapes with no chain (a whole-list
    # literal, a helper returning one tuple).
    ordered =
      if shallow?, do: cons_chain_children(instrs, functions), else: []

    in_order =
      if ordered == [],
        do: from_literals ++ from_cons ++ from_maps ++ from_tuples,
        else: from_literals ++ ordered ++ from_maps

    # Dedup by {module, registered name}: two children of the same module
    # are distinct when they register under different names (three
    # `{DynamicSupervisor, name: ...}` children are three supervisors, not
    # one). Same module and same name (or both nameless) still collapse —
    # without a distinguishing name there is nothing to tell them apart.
    in_order
    # A spec whose module resolved only to the behaviour that starts it
    # (`{GenServer, :start_link, [runtime_mod, ...]}`) names no process
    # module at all; recording "GenServer" as a child says nothing.
    |> Enum.reject(fn {mod, _, _, _, _} ->
      mod in [GenServer, Agent, Task, :gen_server, :gen_statem]
    end)
    |> Enum.uniq_by(fn {mod, _, _, name, _form} -> {mod, name} end)
  end

  # A child list with a runtime element compiles to cons cells:
  #
  #     put_tuple2 x0, [x0, literal: [...]]          {producer, opts}
  #     put_list   x0, literal: [{WorkerA, []}], x0  [{producer, opts} | [...]]
  #     put_list   literal: {TaskSup, ...}, x0, x0   [{TaskSup, ...} | ...]
  #
  # Scanning put_lists in reverse instruction order recovers the literal
  # elements but files the runtime one wherever its tuple happened to be
  # built, so positions — which every ordering rule reads — were wrong
  # whenever a literal and a runtime element were interleaved. Walking
  # the chain from its outermost cell instead reads the list the way the
  # VM builds it: each cell's head, then whatever its tail register held.
  defp cons_chain_children(instrs, functions) do
    indexed = Enum.with_index(instrs)

    consumed =
      MapSet.new(
        for {{:put_list, _head, tail, _dst}, idx} <- indexed,
            reg = operand_register(tail),
            match?({:x, _}, reg) or match?({:y, _}, reg),
            do: {reg, idx}
      )

    # The outermost cell is a put_list whose destination no later
    # put_list consumes as a tail.
    outermost =
      indexed
      |> Enum.filter(&match?({{:put_list, _, _, _}, _}, &1))
      |> Enum.reject(fn {{:put_list, _, _, dst}, idx} ->
        Enum.any?(consumed, fn {reg, at} -> reg == operand_register(dst) and at > idx end)
      end)
      |> List.last()

    case outermost do
      nil ->
        []

      {{:put_list, head, tail, _dst}, idx} ->
        cons_head(head, instrs, idx, functions) ++ cons_tail(tail, instrs, idx, functions)
    end
  end

  defp cons_head({:literal, _} = operand, _instrs, _idx, _functions),
    do: extract_child_from_cons_operand(operand)

  defp cons_head({:atom, _} = operand, _instrs, _idx, _functions),
    do: extract_child_from_cons_operand(operand)

  defp cons_head(operand, instrs, idx, functions) do
    case last_writer(instrs, idx, operand_register(operand)) do
      {{:put_tuple2, _dst, {:list, elements}}, at} ->
        extract_child_from_tuple_elements(elements, instrs, at, functions)

      {{:move, src, _dst}, at} ->
        cons_head(src, instrs, at, functions)

      _ ->
        []
    end
  end

  defp cons_tail({:literal, _} = operand, _instrs, _idx, _functions),
    do: extract_child_from_cons_tail(operand)

  defp cons_tail({:atom, nil}, _instrs, _idx, _functions), do: []
  defp cons_tail(nil, _instrs, _idx, _functions), do: []

  defp cons_tail(operand, instrs, idx, functions) do
    case last_writer(instrs, idx, operand_register(operand)) do
      {{:put_list, head, tail, _dst}, at} ->
        cons_head(head, instrs, at, functions) ++ cons_tail(tail, instrs, at, functions)

      {{:move, {:literal, _} = src, _dst}, _at} ->
        extract_child_from_cons_tail(src)

      {{:move, src, _dst}, at} ->
        cons_tail(src, instrs, at, functions)

      _ ->
        []
    end
  end

  # The instruction before `idx` that last touched `reg`, with its index.
  # Any mention counts, not only the list-building forms the walk knows:
  # a put_map_assoc or a call also writes a register, and skipping past
  # one to an earlier put_tuple2 would read a map spec's `start` tuple as
  # a child of its own. The callers match the known forms and stop at
  # anything else.
  defp last_writer(_instrs, _idx, nil), do: nil

  defp last_writer(instrs, idx, reg) do
    instrs
    |> Enum.with_index()
    |> Enum.take(idx)
    |> Enum.reverse()
    |> Enum.find(fn {instr, _at} -> mentions?(instr, &(&1 == reg)) end)
  end

  # The tuple's register is consumed as a list head, or is x0 immediately
  # before the function returns.
  defp tuple_used_as_spec?(instrs, idx, dst) do
    rest = Enum.drop(instrs, idx + 1)

    # Follow the tuple through register moves (`x0` parked in a `y`
    # slot across a call) to the put_list that consumes it, or to a
    # `Supervisor.child_spec/2` call that takes it as its first argument
    # (a comprehension body normalising `{Mod, arg}` per element).
    {feeds_list?, _aliases} =
      Enum.reduce_while(rest, {false, MapSet.new([dst])}, fn
        {:move, src, to}, {_, aliases} ->
          if MapSet.member?(aliases, operand_register(src)),
            do: {:cont, {false, MapSet.put(aliases, to)}},
            else: {:cont, {false, aliases}}

        {:put_list, head, _tail, _}, {_, aliases} ->
          if MapSet.member?(aliases, operand_register(head)),
            do: {:halt, {true, aliases}},
            else: {:cont, {false, aliases}}

        instr, {_, aliases} = acc ->
          case match_remote_call(instr) do
            {:ok, Supervisor, :child_spec, 2} ->
              if MapSet.member?(aliases, {:x, 0}),
                do: {:halt, {true, aliases}},
                else: {:cont, acc}

            _ ->
              {:cont, acc}
          end
      end)

    returned? =
      dst == {:x, 0} and
        match?(
          [_ | _],
          rest
          |> Enum.reject(&match?({:line, _}, &1))
          |> Enum.take(2)
          |> Enum.filter(&(&1 == :return or match?({:deallocate, _}, &1)))
        )

    feeds_list? or returned?
  end

  defp operand_register({:tr, reg, _}), do: reg
  defp operand_register(reg), do: reg

  defp extract_child_from_cons_operand({:atom, mod}) when is_atom(mod) do
    # Elixir modules only, as for tuples: a lowercase atom at the head of
    # a runtime-built list is a tag, not an Erlang child.
    if String.starts_with?(Atom.to_string(mod), "Elixir."),
      do: [{mod, :permanent, :worker, nil, :shorthand}],
      else: []
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
  # `{GenServer, :start_link, [Mod, args, opts]}` starts Mod, not GenServer;
  # the same for Supervisor/Agent/Task when their first argument names a
  # module. A Supervisor started on a children list stays "Supervisor" —
  # an inline nested tree whose children are built elsewhere.
  defp resolve_start_module({:literal, {behaviour, _, [mod | _]}}, _instrs, _idx)
       when behaviour in [GenServer, Supervisor, Agent, Task, :gen_server, :gen_statem] and
              is_atom(mod) and mod != nil,
       do: mod

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
    list |> list_elements() |> Enum.flat_map(&extract_single_child_spec/1)
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
  # {Id, {Mod, F, Args}, Restart, Shutdown, Type, Modules} — OTP's tuple form
  # Module — bare module name (uses Module.child_spec/1)
  #
  # Keyword pairs like {:strategy, :one_for_one} also match {atom, value},
  # so we filter with module_name?/1 to reject non-module atoms.
  defp extract_single_child_spec({PartitionSupervisor, opts}) when is_list(opts) do
    # PartitionSupervisor is a wrapper — extract the underlying child_spec
    # so analyses see the real worker module instead of PartitionSupervisor.
    case opts |> list_elements() |> Keyword.get(:child_spec) do
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
  # OTP's tuple form, which Erlang supervisors still write (zotonic's
  # zotonic_core_sup, ejabberd's, mongooseim's): the restart and type at
  # their fixed positions tell it from any other 6-tuple, and they are
  # stated, so the form is explicit. The child is the start function's
  # module, as for a map spec.
  defp extract_single_child_spec({_id, {mod, _fun, args}, restart, _shutdown, type, modules})
       when is_atom(mod) and restart in @restarts and type in @child_types do
    case spec_module(modules, mod, args) do
      nil -> []
      child -> [{child, restart, type, nil, :explicit}]
    end
  end

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
    # A bare-atom child is Elixir shorthand for `{mod, []}`; Erlang code
    # never spells a child spec that way, so a lowercase atom here is a
    # tag in some other literal list, not a module.
    if String.starts_with?(Atom.to_string(mod), "Elixir."),
      do: [{mod, :permanent, :worker, nil, :shorthand}],
      else: []
  end

  defp extract_single_child_spec(_), do: []

  # The child of an OTP tuple spec: its one callback module when the spec
  # lists one (`[Mod]`, what the release handler upgrades), else the
  # module its start function starts. A start through a wrapper of the
  # supervisor's own (mongooseim's `{ejabberd_sup, start_linked_child,
  # [Mod, Args]}`) names the child only in the modules list, so a list
  # holding a value the bytecode does not show names no child: nil, and
  # the spec is left out rather than read as the wrapper.
  defp spec_module(modules, mod, args) do
    cond do
      not is_list(modules) and modules != :dynamic -> nil
      is_list(modules) and :dynamic in modules -> nil
      match?([m] when is_atom(m) and m not in [nil, true, false], modules) -> hd(modules)
      true -> start_module(mod, args)
    end
  end

  # The module a start function starts: its own, or for a behaviour's
  # start function the first module among its arguments.
  defp start_module(mod, args) when mod in @starting_behaviours and is_list(args) do
    Enum.find(args, mod, &(is_atom(&1) and &1 not in [nil, true, false, :dynamic]))
  end

  defp start_module(mod, _args), do: mod

  # An operand's value as far as the bytecode shows it: a literal, an
  # atom, or what reaches a register (`:dynamic` where it cannot tell).
  defp operand_value({:literal, value}, _instrs, _idx), do: {:ok, value}
  defp operand_value({:atom, value}, _instrs, _idx), do: {:ok, value}
  defp operand_value(nil, _instrs, _idx), do: {:ok, []}

  defp operand_value(operand, instrs, idx) do
    case element_register(operand) do
      nil -> :error
      reg -> resolve_register(instrs, idx, reg)
    end
  end

  # A child spec's `:name` option registers the process under a name — the
  # same name a `DynamicSupervisor.start_child(name, _)` call later targets.
  # Only atoms are name-anchorable; `{:via, _, _}`/`{:global, _}` names are
  # skipped. The scan tolerates non-keyword option lists (mixed positional
  # args) by matching `{:name, atom}` pairs directly.
  defp child_name(opts) when is_list(opts) do
    opts
    |> list_elements()
    |> Enum.find_value(fn
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

  # OTP's tuple form built at run time (an argument computed in init/1):
  # `{Id, Start, Restart, Shutdown, Type, Modules}` with the restart and
  # the type literal atoms at their positions, and the start's module
  # resolved through the register that holds it.
  defp extract_child_from_tuple_elements(
         [_id, start, {:atom, restart}, _shutdown, {:atom, type}, modules],
         instrs,
         idx,
         _functions
       )
       when restart in @restarts and type in @child_types do
    with {:ok, {mod, _fun, args}} when is_atom(mod) and mod != :dynamic <-
           operand_value(start, instrs, idx),
         {:ok, modules} <- operand_value(modules, instrs, idx),
         child when child != nil <- spec_module(modules, mod, args) do
      [{child, restart, type, nil, :explicit}]
    else
      _ -> []
    end
  end

  defp extract_child_from_tuple_elements(elements, instrs, idx, functions) do
    # Look for module atoms in tuple construction that look like child
    # specs. module_name?/1, not Code.ensure_loaded?/1: the analyzed
    # project's modules are rarely loadable in the analyzing VM, and an
    # Elixir-prefixed atom is a module name regardless.
    # Elixir modules only: an Erlang-style lowercase atom in a tuple is a
    # tag (`{:supervisor, ...}`, `{:queue, ...}`) far more often than an
    # Erlang module started as a child, and Erlang children arrive as maps.
    modules =
      Enum.filter(elements, fn
        {:atom, mod} when is_atom(mod) -> String.starts_with?(Atom.to_string(mod), "Elixir.")
        _ -> false
      end)

    case modules do
      # The `name:` is runtime-built, so a literal read finds nothing — but
      # a `{:via, Registry, _}` registration is still recoverable by tracing
      # the opts through its construction to the via call.
      [{:atom, mod} | _] ->
        [{mod, :permanent, :worker, via_child_name(elements, instrs, idx, functions), :shorthand}]

      [] ->
        case defaulted_module(elements, instrs, idx) do
          nil ->
            []

          mod ->
            [
              {mod, :permanent, :worker, via_child_name(elements, instrs, idx, functions),
               :shorthand}
            ]
        end
    end
  end

  # `{Keyword.get(opts, :producer, Producer), opts}`: the module is chosen
  # at runtime, with a literal default that is the child unless a caller
  # says otherwise. Oban's queue supervisor builds its producer this way,
  # and dropping the child also shifted every later sibling's position.
  # Traced from the tuple's first element back to the Keyword.get/3 or
  # Map.get/3 whose result it holds, then to that call's third argument.
  defp defaulted_module([first | _rest], instrs, idx) do
    with reg when reg != nil <- element_register(first),
         {:ok, {getter, :get, 3}, origin} when getter in [Keyword, Map] <-
           call_result_origin(instrs, idx, reg),
         {:ok, mod} when is_atom(mod) <- resolve_register(instrs, origin, {:x, 2}),
         true <- String.starts_with?(Atom.to_string(mod), "Elixir.") do
      mod
    else
      _ -> nil
    end
  end

  defp defaulted_module(_elements, _instrs, _idx), do: nil

  defp element_register({:tr, reg, _type}), do: element_register(reg)
  defp element_register({:x, _} = reg), do: reg
  defp element_register({:y, _} = reg), do: reg
  defp element_register(_other), do: nil

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
