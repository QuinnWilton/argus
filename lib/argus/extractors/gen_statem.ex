defmodule Argus.Extractors.GenStatem do
  @moduledoc """
  gen_statem extractor.

  Detects `gen_statem` modules and extracts their state machine structure:
  states, transitions, and timeouts. Supports `state_functions` callback
  mode (function names = states) and `handle_event_function` mode (state
  passed as argument).

  ## Approach

  For `state_functions` mode, each exported function whose name isn't a
  standard gen_statem callback is treated as a state handler. Transitions
  are detected by scanning return tuples for `{:next_state, target, ...}`
  patterns.

  For `handle_event_function` mode, the `handle_event/4` function is
  analyzed for state argument patterns.

  ## Emitted facts

  - `statem_module(mod, callback_mode)` — gen_statem module identification
  - `statem_state(mod, state)` — state in the machine
  - `statem_transition(mod, from, event, to)` — state transition
  - `statem_timeout(mod, state, type, value)` — timeout set per state
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      find_function: 3,
      get_behaviours: 1,
      scan_return_tuples: 1,
      track_dynamic: 5,
      track_imprecision: 5
    ]

  alias Argus.Pipeline.Normalize

  # Standard gen_statem callbacks that are not state functions.
  @non_state_callbacks MapSet.new([
                         :init,
                         :callback_mode,
                         :handle_event,
                         :terminate,
                         :code_change,
                         :format_status,
                         :handle_common,
                         :module_info
                       ])

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    attrs = module_data.attributes
    behaviours = get_behaviours(attrs)

    if :gen_statem in behaviours do
      extract_statem(mod, module_data)
    else
      %{}
    end
  end

  defp extract_statem(mod, module_data) do
    mod_str = inspect(mod)
    functions = module_data.functions
    exports = export_set(module_data)
    locally_called = locally_called_set(mod, functions)

    callback_mode = detect_callback_mode(functions)

    facts =
      %{}
      |> maybe_track_unknown_callback_mode(mod_str, callback_mode)
      |> add_fact(:statem_module, [mod_str, to_string(callback_mode)])

    facts = extract_initial_states(facts, mod_str, functions)

    case callback_mode do
      :state_functions ->
        extract_state_functions(facts, mod_str, functions, exports, locally_called)

      :handle_event_function ->
        extract_handle_event(facts, mod_str, functions)

      :unknown ->
        facts
    end
  end

  # The initial state(s) from init/1's `{:ok, State, Data}` /
  # `{:ok, State, Data, Actions}` return — read directly rather than
  # inferred from the transition graph's topology. A machine with several
  # init clauses (Redix's Cluster.Manager returns :ready or :disconnected)
  # emits one row per resolvable clause; a computed state emits none.
  defp extract_initial_states(facts, mod_str, functions) do
    case find_function(functions, :init, 1) do
      nil -> facts
      instrs -> Enum.reduce(instrs, facts, &initial_state_from_instr(&1, mod_str, &2))
    end
  end

  # `{:ok, State, Data}` returns take two bytecode shapes: a put_tuple2
  # when Data is runtime-built (the connection-machine case), or a single
  # move of a fully-literal tuple when every element is constant
  # (`{:ok, :idle, %{}}`). Handle both — missing the literal form leaves
  # the analysis with no init state, and the topological fallback then
  # misreads any no-incoming source (a dead state) as the entry point.
  defp initial_state_from_instr({:put_tuple2, _dst, {:list, elements}}, mod_str, facts) do
    case elements do
      [{:atom, :ok}, {:atom, state} | _] -> add_initial(facts, mod_str, state)
      _ -> facts
    end
  end

  defp initial_state_from_instr({:move, {:literal, {:ok, state, _data}}, _dst}, mod_str, facts)
       when is_atom(state) do
    add_initial(facts, mod_str, state)
  end

  defp initial_state_from_instr(
         {:move, {:literal, {:ok, state, _data, _acts}}, _dst},
         mod_str,
         facts
       )
       when is_atom(state) do
    add_initial(facts, mod_str, state)
  end

  defp initial_state_from_instr(_instr, _mod_str, facts), do: facts

  defp add_initial(facts, _mod_str, state) when state in [nil, :ok], do: facts

  defp add_initial(facts, mod_str, state) do
    add_fact(facts, :statem_initial, [mod_str, to_string(state)])
  end

  # Surface gen_statem modules whose callback_mode/0 couldn't be resolved
  # — they may declare valid state machines but we can't pick the right
  # extraction path without the mode.
  defp maybe_track_unknown_callback_mode(facts, mod_str, :unknown) do
    track_imprecision(
      facts,
      synthetic_ctx(mod_str, "callback_mode/0"),
      :statem_callback_mode_unknown,
      :statem_module,
      :missing
    )
  end

  defp maybe_track_unknown_callback_mode(facts, _mod_str, _mode), do: facts

  # gen_statem extractors operate on whole functions, not single
  # instructions — build a synthetic ctx so tracking helpers have a
  # func_id to attribute events to.
  defp synthetic_ctx(func_id) when is_binary(func_id) do
    %{func_id: func_id, instrs: [], idx: 0}
  end

  defp synthetic_ctx(mod_str, func_label) do
    synthetic_ctx("#{mod_str}:#{func_label}")
  end

  # The module's exported {name, arity} pairs. Handles both beam_disasm
  # export shapes (same normalization as Argus.Pipeline.Emit); an absent
  # or malformed exports list yields an empty set.
  defp export_set(module_data) do
    module_data
    |> Map.get(:exports, [])
    |> MapSet.new(fn
      {name, arity, _label} -> {name, arity}
      {:atom, name, arity, _label} -> {name, arity}
    end)
  end

  # The {name, arity} pairs called directly by some function in this
  # module. gen_statem dispatches to a state function externally
  # (`apply(Mod, State, [EventType, EventContent, Data])`), so a real
  # state is never the target of a local call. A helper that happens to
  # be exported, arity-3, and returns a gen_statem action tuple on behalf
  # of its caller (Redix's `disconnect(data, reason, flag)` returning
  # `{:next_state, :disconnected, …}`) IS locally called — that is what
  # separates it from a genuine dead state. (A state function delegating
  # by a direct call to a sibling state would be excluded, a rare and
  # acceptable false negative.)
  defp locally_called_set(mod, functions) do
    labels =
      for {:function, name, arity, entry, _instrs} <- functions,
          into: %{},
          do: {entry, {name, arity}}

    for {:function, _n, _a, _e, instrs} <- functions,
        instr <- instrs,
        fa = local_call_target(instr, mod, labels),
        fa != nil,
        into: MapSet.new() do
      fa
    end
  end

  defp local_call_target({:call, _arity, target}, mod, labels),
    do: resolve_call_fa(target, mod, labels)

  defp local_call_target({:call_only, _arity, target}, mod, labels),
    do: resolve_call_fa(target, mod, labels)

  defp local_call_target({:call_last, _arity, target, _dealloc}, mod, labels),
    do: resolve_call_fa(target, mod, labels)

  defp local_call_target(_instr, _mod, _labels), do: nil

  defp resolve_call_fa({mod, func, arity}, mod, _labels), do: {func, arity}
  defp resolve_call_fa({:f, label}, _mod, labels), do: Map.get(labels, label)
  defp resolve_call_fa(_target, _mod, _labels), do: nil

  # Detect the callback mode by finding the callback_mode/0 function and
  # resolving its return value.
  defp detect_callback_mode(functions) do
    case find_function(functions, :callback_mode, 0) do
      nil ->
        :unknown

      instrs ->
        Enum.find_value(instrs, :unknown, fn
          {:move, {:atom, :state_functions}, _} -> :state_functions
          {:move, {:atom, :handle_event_function}, _} -> :handle_event_function
          {:move, {:literal, modes}, _} when is_list(modes) -> detect_mode_from_list(modes)
          _ -> nil
        end)
    end
  end

  defp detect_mode_from_list(modes) do
    cond do
      :state_functions in modes -> :state_functions
      :handle_event_function in modes -> :handle_event_function
      true -> :unknown
    end
  end

  # In state_functions mode, a state handler is an arity-3 function that
  # is exported, not a standard callback, not called locally, and returns
  # a gen_statem action. Each filter removes a distinct false-positive
  # class seen on the corpus:
  #
  #   * exported — gen_statem dispatches a state via
  #     `Module:StateName(EventType, EventContent, Data)`, which only
  #     reaches exported functions; excludes private helpers (`setopts/3`)
  #     and compiler-lifted closures (`-handle_pubsub_msg/2-fun-0-`,
  #     emitted as private arity-3 top-level functions).
  #   * not locally called — a state is dispatched externally, never by a
  #     sibling; excludes exported helpers a state calls directly.
  #   * returns an action — every state clause returns a gen_statem action
  #     tuple/atom; excludes exported client wrappers (`connect_to_node/3`
  #     returning a `:gen_statem.call` result) and plain lookup helpers
  #     (`get_connection/3`).
  #
  # Together these cut the corpus's gen_statem findings from 108 (all
  # false) to the genuine dead-state cases.
  defp extract_state_functions(facts, mod_str, functions, exports, locally_called) do
    state_funs =
      Enum.filter(functions, fn {:function, name, arity, _entry, instrs} ->
        arity == 3 and
          MapSet.member?(exports, {name, arity}) and
          not MapSet.member?(@non_state_callbacks, name) and
          not MapSet.member?(locally_called, {name, arity}) and
          returns_statem_action?(instrs)
      end)

    # Register all states. In state_functions mode the state IS a
    # function — its ID is the natural site.
    facts =
      Enum.reduce(state_funs, facts, fn {:function, name, arity, _, _}, acc ->
        add_fact(acc, :statem_state, [mod_str, to_string(name), "#{mod_str}:#{name}/#{arity}"])
      end)

    # Extract transitions and timeouts from each state function.
    Enum.reduce(state_funs, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      state_name = to_string(name)
      func_id = Normalize.func_id(String.to_atom(mod_str), name, arity)

      acc
      |> extract_transitions(mod_str, state_name, instrs, func_id)
      |> extract_timeouts(mod_str, state_name, instrs, func_id)
    end)
  end

  # gen_statem callback-result atoms. A real state function's body always
  # returns one of these (the behaviour requires it); a client-API wrapper
  # (`:gen_statem.call`) or a plain lookup helper never does. Requiring an
  # action return separates the two — on the corpus it excluded exported
  # arity-3 helpers like `connect_to_node/3` and `get_connection/3` that
  # the export filter alone could not.
  @statem_action_heads MapSet.new([
                         :next_state,
                         :keep_state,
                         :keep_state_and_data,
                         :repeat_state,
                         :repeat_state_and_data,
                         :stop,
                         :stop_and_reply
                       ])

  # The two actions that are also valid as bare atoms (not just tuples).
  @statem_bare_actions MapSet.new([:keep_state_and_data, :repeat_state_and_data])

  defp returns_statem_action?(instrs) do
    tuple_action_return?(instrs) or bare_action_return?(instrs)
  end

  defp tuple_action_return?(instrs) do
    instrs
    |> scan_return_tuples()
    |> Enum.any?(fn
      {_idx, [{:atom, head} | _]} -> MapSet.member?(@statem_action_heads, head)
      _ -> false
    end)
  end

  # A bare `:keep_state_and_data` / `:repeat_state_and_data` return loads
  # the atom into a register. Those atoms are used only as gen_statem
  # returns, so their presence anywhere in the body is a safe signal.
  defp bare_action_return?(instrs) do
    Enum.any?(instrs, fn
      {:move, {:atom, atom}, _dst} -> MapSet.member?(@statem_bare_actions, atom)
      _ -> false
    end)
  end

  # In handle_event_function mode there is a single handle_event/4 callback
  # and states are ordinary data values. We record transitions (real
  # `{:next_state, X}` targets) but do NOT harvest candidate states from
  # atom comparisons in the body: that swept in message tags (`:DOWN`,
  # `:EXIT`), command atoms, module aliases, and compiler error atoms
  # (`:badarg`) as phantom states. The structural rules
  # (unreachable_state, terminal_without_stop) are scoped to
  # state_functions mode, where states are real callback functions, so no
  # candidate-state harvesting is needed here.
  defp extract_handle_event(facts, mod_str, functions) do
    case find_function(functions, :handle_event, 4) do
      nil ->
        facts

      instrs ->
        facts
        |> extract_transitions(mod_str, "handle_event", instrs, "#{mod_str}:handle_event/4")
        |> extract_timeouts(mod_str, "handle_event", instrs, "#{mod_str}:handle_event/4")
    end
  end

  # Extract transitions from return tuples. Look for {:next_state, target, ...}
  # patterns in put_tuple2 instructions.
  defp extract_transitions(facts, mod_str, from_state, instrs, func_id) do
    ctx = synthetic_ctx(func_id)

    facts
    |> transitions_from_tuples(mod_str, from_state, instrs, func_id, ctx)
    |> transitions_from_bare_actions(mod_str, from_state, instrs)
  end

  defp transitions_from_tuples(facts, mod_str, from_state, instrs, func_id, ctx) do
    instrs
    |> scan_return_tuples()
    |> Enum.reduce(facts, fn {idx, elements}, acc ->
      case elements do
        # {:next_state, target_state, data} or {:next_state, target_state, data, actions}.
        [{:atom, :next_state}, target | _] ->
          to_state = resolve_element_value(target)

          acc
          |> track_dynamic(to_state, ctx, :statem_transition_target, :statem_transition)
          |> add_fact(:statem_transition, [mod_str, from_state, "event", to_state])
          |> maybe_add_target_state(mod_str, to_state, InstrId.mint(func_id, idx))

        # {:keep_state, …} / {:keep_state_and_data, …} / {:repeat_state, …} /
        # {:repeat_state_and_data, …} — the machine stays in the current
        # state, so the edge is a self-transition (outgoing, so the state
        # is not terminal).
        [{:atom, action} | _]
        when action in [:keep_state, :keep_state_and_data, :repeat_state, :repeat_state_and_data] ->
          add_fact(acc, :statem_transition, [mod_str, from_state, "event", from_state])

        # {:stop, …} / {:stop_and_reply, …} — terminal transition.
        [{:atom, action} | _] when action in [:stop, :stop_and_reply] ->
          add_fact(acc, :statem_transition, [mod_str, from_state, "event", "stop"])

        _ ->
          acc
      end
    end)
  end

  # Bare `:keep_state_and_data` / `:repeat_state_and_data` returns (the
  # atom, not a tuple) are self-transitions the return-tuple scan cannot
  # see. Recording them keeps a state that only ever returns a bare
  # keep/repeat from being misread as an outgoing-less terminal state.
  defp transitions_from_bare_actions(facts, mod_str, from_state, instrs) do
    if bare_action_return?(instrs) do
      add_fact(facts, :statem_transition, [mod_str, from_state, "event", from_state])
    else
      facts
    end
  end

  # Also scan for literal return values moved to x0. The site is the
  # return-tuple construction naming the target state.
  defp maybe_add_target_state(facts, mod_str, to_state, site) do
    if to_state != "dynamic" and to_state != "stop" do
      add_fact(facts, :statem_state, [mod_str, to_state, site])
    else
      facts
    end
  end

  # Extract timeouts from return tuple action lists.
  # Timeouts appear in two forms:
  # 1. As standalone put_tuple2 timeout tuples.
  # 2. As literal lists embedded in the elements of a return tuple put_tuple2,
  #    e.g. {:put_tuple2, _, {:list, [atom: :next_state, atom: :processing, x: 2,
  #           literal: [{:state_timeout, 5000, :timeout}]]}}.
  defp extract_timeouts(facts, mod_str, state_name, instrs, func_id) do
    ctx = synthetic_ctx(func_id)

    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{:put_tuple2, _, {:list, elements}}, _idx}, acc ->
        acc
        |> maybe_timeout_tuple(mod_str, state_name, elements, ctx)
        |> extract_timeouts_from_elements(mod_str, state_name, elements)

      {{:move, {:literal, actions}, _}, _idx}, acc when is_list(actions) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, actions)

      _, acc ->
        acc
    end)
  end

  # Check if this put_tuple2 is itself a timeout tuple.
  defp maybe_timeout_tuple(
         facts,
         mod_str,
         state_name,
         [{:atom, :state_timeout}, timeout_val | _],
         ctx
       ) do
    value = resolve_element_value(timeout_val)

    facts
    |> track_dynamic(value, ctx, :statem_timeout_value, :statem_timeout)
    |> add_fact(:statem_timeout, [mod_str, state_name, "state_timeout", value])
  end

  defp maybe_timeout_tuple(
         facts,
         mod_str,
         state_name,
         [{:atom, :timeout}, timeout_val | _],
         ctx
       ) do
    value = resolve_element_value(timeout_val)

    facts
    |> track_dynamic(value, ctx, :statem_timeout_value, :statem_timeout)
    |> add_fact(:statem_timeout, [mod_str, state_name, "event_timeout", value])
  end

  defp maybe_timeout_tuple(facts, _mod_str, _state_name, _elements, _ctx), do: facts

  # Scan literal elements inside a put_tuple2 for action lists containing timeouts.
  defp extract_timeouts_from_elements(facts, mod_str, state_name, elements) do
    Enum.reduce(elements, facts, fn
      {:literal, actions}, acc when is_list(actions) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, actions)

      _, acc ->
        acc
    end)
  end

  defp extract_timeouts_from_literal_actions(facts, mod_str, state_name, actions) do
    Enum.reduce(actions, facts, fn
      {:state_timeout, value, _}, acc ->
        add_fact(acc, :statem_timeout, [mod_str, state_name, "state_timeout", to_string(value)])

      {:timeout, value, _}, acc ->
        add_fact(acc, :statem_timeout, [mod_str, state_name, "event_timeout", to_string(value)])

      {name, value, _}, acc when is_atom(name) ->
        add_fact(acc, :statem_timeout, [mod_str, state_name, "generic", to_string(value)])

      _, acc ->
        acc
    end)
  end

  defp resolve_element_value({:atom, a}), do: to_string(a)
  defp resolve_element_value({:integer, n}), do: to_string(n)
  defp resolve_element_value({:literal, v}) when is_atom(v), do: to_string(v)
  defp resolve_element_value({:literal, v}) when is_integer(v), do: to_string(v)
  defp resolve_element_value(_), do: "dynamic"
end
