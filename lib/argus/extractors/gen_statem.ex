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

  - `statem_event_clause(mod, func, event_type)` — a clause head matches this event type
  - `statem_call_unreplied(mod, func, site, tag)` — a `{:call, from}` clause
    whose last pattern test is `site` (comparing against `tag`) returns
    without replying, postponing, or keeping `from`
  - `statem_info_catchall(mod, func)` — some clause accepts `:info` with any content
  - `statem_event_catchall(mod, func)` — some clause accepts any event
  - `statem_info_tag(mod, func, tag)` — an atom the callback compares,
    over-approximating the content tags it takes
  - `statem_info_open(mod, func, shape)` — a clause takes the content by
    its shape alone (`CallbackTag.MessageClauses.open_shapes/2` on `{x, 1}`)

  The clause-head walk behind the last three lives in
  `Argus.Extractors.GenStatem.EventClauses`.

  - `statem_module(mod, callback_mode)` — gen_statem module identification
  - `statem_state(mod, state, func)` — a state in the machine, and the
    state function that handles it
  - `statem_transition(mod, from, event, to)` — state transition
  - `statem_helper_transition(mod, func, to)` — a transition a function
    that is not a state function returns on a state's behalf
  - `statem_returns_call(mod, func, callee)` — a function that may return
    what a call returns (a tail call, a call's result, a throw): the local
    callee, or `dynamic`
  - `statem_timeout(mod, state, type, value)` — timeout set per state
  - `statem_insert(id, func, clause, type, content)` — a `{:next_event,
    type, content}` action built at `id`: an event the machine inserts
    ahead of its mailbox, which only such an action can make of type
    `:internal`
  - `event_functions/1` names the functions gen_statem hands an event
    (`handle_event/4`, the state functions), whose clauses
    `Argus.Extractor.Dispatch.event_tags/3` tells apart by the event's
    type and content together
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.GenStarts
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.CallbackTag.MessageClauses
  alias Argus.Extractors.GenStatem.{CallClauses, EventClauses}
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Helpers,
    only: [cfg: 3, find_function: 3, get_behaviours: 1, instructions_from_label: 2]

  import Argus.Extractor.Facts, only: [add_fact: 3, track_dynamic: 5, track_imprecision: 5]
  import Argus.Extractor.Shapes, only: [return_shapes: 1]
  import Argus.Extractor.Terms, only: [list_elements: 1]
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
  def relations,
    do: [
      :statem_event_catchall,
      :statem_event_clause,
      :statem_call_unreplied,
      :statem_helper_transition,
      :statem_info_catchall,
      :statem_info_open,
      :statem_info_tag,
      :statem_initial,
      :statem_insert,
      :statem_module,
      :statem_returns_call,
      :statem_state,
      :statem_timeout,
      :statem_transition
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module
    attrs = module_data.attributes
    # A module a start of its own names a gen_statem's callback module is
    # one, declared or not (OTP's group: `gen_statem:start(?MODULE, ...)`).
    behaviours = get_behaviours(attrs) ++ GenStarts.own_behaviours(module_data)

    # The GenStateMachine library's `use` declares its own behaviour,
    # whose callbacks are gen_statem's.
    if :gen_statem in behaviours or GenStateMachine in behaviours do
      extract_statem(mod, module_data)
    else
      %{}
    end
  end

  @doc """
  The functions of `module_data`'s module gen_statem hands an event, as
  `{name, arity}` pairs: its `handle_event/4` under `:handle_event_function`,
  its state functions under `:state_functions` (the ones this extractor
  registers as states), none for a module that is no gen_statem or whose
  callback mode it cannot read. Their clauses are picked by the event's
  type and content together, which `Argus.Extractor.Dispatch.event_tags/3`
  reads where `argument_tags/2` reads a callback's one message argument.
  """
  @spec event_functions(Argus.Extractor.module_data()) :: [{atom(), arity()}]
  def event_functions(module_data) do
    behaviours = get_behaviours(module_data.attributes) ++ GenStarts.own_behaviours(module_data)

    if :gen_statem in behaviours or GenStateMachine in behaviours do
      mod = module_data.module
      functions = module_data.functions

      case detect_callback_mode(functions) do
        :state_functions ->
          exports = export_set(module_data)
          locally_called = locally_called_set(mod, functions)

          for {:function, name, arity, _entry, _instrs} <-
                state_functions(module_data, exports, locally_called),
              do: {name, arity}

        :handle_event_function ->
          if find_function(functions, :handle_event, 4), do: [{:handle_event, 4}], else: []

        :unknown ->
          []
      end
    else
      []
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

    facts =
      facts
      |> extract_initial_states(mod_str, functions)
      |> extract_inserts(mod, functions, event_functions(module_data))

    case callback_mode do
      :state_functions ->
        extract_state_functions(facts, mod, module_data, exports, locally_called)

      :handle_event_function ->
        extract_handle_event(facts, mod_str, module_data)

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

  # ── Inserted events ─────────────────────────────────────────────────
  #
  # A `{:next_event, type, content}` action, built in any function of the
  # machine's module (a state function, init/1, handle_event/4, a helper
  # whose result one returns): gen_statem runs the event it inserts before
  # anything in the mailbox. An `:internal` event is made by no one else.
  # The tuple is read where it is built (`put_tuple2`) or where a literal
  # holds it (`[{:next_event, :internal, :go}]`); whether it is returned
  # is not asked, so one built for another use counts too. `type` is the
  # event type as a clause head tells it, `{:call, from}` by its tag
  # (`:call`), and `*` when the function does not spell it (a parameter:
  # ra's `{next_event, EvtType, Evt}`), and `content` the content's atom,
  # or the atom a tuple content is headed by, `*` where it spells none.
  # The clause is the tag the function's first argument was established to
  # be on the paths to the tuple (`Dispatch.argument_tags/2`; for an event
  # function, its event's type and content, `Dispatch.event_tags/3`), `*`
  # where none was.
  defp extract_inserts(facts, mod, functions, events) do
    Enum.reduce(functions, facts, fn {:function, name, arity, _entry, instrs}, acc ->
      inserts =
        instrs
        |> Enum.with_index()
        |> Enum.flat_map(fn {instr, idx} ->
          for event <- inserted_events(instrs, idx, instr), do: {idx, event}
        end)

      event? = {name, arity} in events
      emit_inserts(acc, InstrId.func_id(mod, name, arity), instrs, inserts, event?)
    end)
  end

  defp emit_inserts(facts, _func_id, _instrs, [], _event?), do: facts

  defp emit_inserts(facts, func_id, instrs, inserts, event?) do
    tags = Dispatch.clause_tags(instrs, event?)

    inserts
    |> Enum.flat_map(fn {idx, {type, content}} ->
      for clause <- insert_clauses(Map.get(tags, idx)), do: {idx, clause, type, content}
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(facts, fn {idx, clause, type, content}, acc ->
      add_fact(acc, :statem_insert, [InstrId.mint(func_id, idx), func_id, clause, type, content])
    end)
  end

  defp insert_clauses(nil), do: ["*"]

  defp insert_clauses(set) do
    if MapSet.member?(set, :any), do: ["*"], else: Enum.sort(set)
  end

  defp inserted_events(
         instrs,
         idx,
         {:put_tuple2, _dst, {:list, [{:atom, :next_event}, type, content]}}
       ),
       do: [{event_type(instrs, idx, type), event_type(instrs, idx, content)}]

  defp inserted_events(_instrs, _idx, instr) when is_tuple(instr) do
    instr |> Tuple.to_list() |> Enum.flat_map(&operand_inserts/1)
  end

  defp inserted_events(_instrs, _idx, _instr), do: []

  # The literals an operand holds: itself, or the elements of a list
  # operand (`put_tuple2`'s and `put_list`'s).
  defp operand_inserts({:literal, term}), do: literal_inserts(term)
  defp operand_inserts({:list, elements}), do: Enum.flat_map(elements, &operand_inserts/1)
  defp operand_inserts(_operand), do: []

  defp literal_inserts({:next_event, type, content}),
    do: [{literal_event_type(type), literal_event_type(content)}]

  defp literal_inserts(list) when is_list(list) do
    list |> list_elements() |> Enum.flat_map(&literal_inserts/1)
  end

  defp literal_inserts(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.flat_map(&literal_inserts/1)
  end

  defp literal_inserts(_term), do: []

  defp literal_event_type(type) when is_atom(type), do: inspect(type)

  defp literal_event_type(type)
       when is_tuple(type) and tuple_size(type) > 0 and is_atom(elem(type, 0)),
       do: inspect(elem(type, 0))

  defp literal_event_type(_type), do: "*"

  defp event_type(_instrs, _idx, {:atom, type}), do: inspect(type)
  defp event_type(_instrs, _idx, {:literal, type}), do: literal_event_type(type)

  defp event_type(instrs, idx, element) do
    with {kind, _} = reg when kind in [:x, :y] <- Instr.register(element),
         [w] when is_integer(w) <- Resolve.writers(instrs, idx, reg) do
      case Reaching.at(instrs, w) do
        {:put_tuple2, _dst, {:list, [{:atom, head} | _]}} -> inspect(head)
        {:move, {:atom, type}, _dst} -> inspect(type)
        {:move, {:literal, type}, _dst} -> literal_event_type(type)
        _ -> "*"
      end
    else
      _ -> "*"
    end
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
  # module other than to re-dispatch an event to a state. gen_statem
  # dispatches to a state function externally (`apply(Mod, State,
  # [EventType, EventContent, Data])`), so a state is the target of a
  # local call only when a function hands it an event: its caller's own
  # (ra's `leader(EventType, Msg, State)` again with a rewritten message,
  # its `terminating_leader/3` running `leader/3`'s clauses) or one it
  # makes (`receive_snapshot(info, receive_snapshot_timeout, State)`). A
  # helper that happens to be exported, arity-3, and returns a gen_statem
  # action tuple on behalf of its caller (Redix's `disconnect(data,
  # reason, flag)` returning `{:next_state, :disconnected, …}`) is called
  # with something else first — that is what separates it from a genuine
  # dead state. A function an event is re-dispatched to is a state only
  # when a transition of the module names it (named_states/2): a shared
  # event handler no transition enters stays a helper.
  defp locally_called_set(mod, functions) do
    labels = function_labels(functions)
    named = named_states(mod, functions)

    calls =
      for {:function, _n, _a, _e, instrs} <- functions,
          {instr, idx} <- Enum.with_index(instrs),
          fa = local_call_target(instr, mod, labels),
          fa != nil,
          do: {fa, redispatch?(instrs, idx)}

    helpers = for {fa, false} <- calls, into: MapSet.new(), do: fa

    for {{name, _arity} = fa, true} <- calls,
        not MapSet.member?(named, name),
        into: helpers,
        do: fa
  end

  @event_types [:enter, :internal, :info, :cast, :timeout, :state_timeout]

  # The call at idx hands its callee an event first: the caller's own
  # first argument, or an event type.
  defp redispatch?(instrs, idx) do
    case Resolve.arg_position(instrs, idx, {:x, 0}) do
      {:ok, 0} ->
        true

      _ ->
        case Resolve.resolve_register(instrs, idx, {:x, 0}) do
          {:ok, type} when type in @event_types -> true
          _ -> false
        end
    end
  end

  # The states the module's transitions name: a literal
  # `{:next_state, state, ...}` in any function, init/1's `{:ok, state,
  # ...}`, and the literal a call hands a local helper whose return makes
  # that parameter the target (ra's `next_state(follower, State,
  # Actions)`, whose `{next_state, Next, ...}` reads its first parameter).
  defp named_states(mod, functions) do
    labels = function_labels(functions)
    target_params = target_params(functions)

    literal =
      for {:function, name, arity, _e, instrs} <- functions,
          {_idx, elements} <- return_shapes(instrs),
          state <- named_target({name, arity}, elements),
          into: MapSet.new(),
          do: state

    for {:function, _n, _a, _e, instrs} <- functions,
        {instr, idx} <- Enum.with_index(instrs),
        fa = local_call_target(instr, mod, labels),
        k <- Map.get(target_params, fa, []),
        {:ok, state} <- [Resolve.resolve_register(instrs, idx, {:x, k})],
        is_atom(state),
        into: literal,
        do: state
  end

  defp named_target(_fa, [{:atom, :next_state}, {:atom, state} | _]), do: [state]
  defp named_target({:init, 1}, [{:atom, :ok}, {:atom, state} | _]), do: [state]
  defp named_target(_fa, _elements), do: []

  # For each function, the parameters a `{:next_state, target, ...}` it
  # returns takes its target from.
  defp target_params(functions) do
    for {:function, name, arity, _e, instrs} <- functions,
        {idx, [{:atom, :next_state}, target | _]} <- return_shapes(instrs),
        {kind, _} = reg <- [Instr.register(target)],
        kind in [:x, :y],
        {:ok, k} <- [Resolve.arg_position(instrs, idx, reg)],
        reduce: %{} do
      acc -> Map.update(acc, {name, arity}, [k], &Enum.uniq([k | &1]))
    end
  end

  defp function_labels(functions) do
    for {:function, name, arity, entry, _instrs} <- functions,
        into: %{},
        do: {entry, {name, arity}}
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
    modes = list_elements(modes)

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
  #   * not locally called but to be handed an event — a state is
  #     dispatched externally, and by a state that re-dispatches an event
  #     to it when a transition names it (locally_called_set/2); excludes
  #     exported helpers a state calls directly.
  #   * returns an action — every state clause returns a gen_statem action
  #     tuple/atom, itself or through a local function whose result it
  #     returns (a state whose every clause ends in `handle(msg, data)`);
  #     excludes exported client wrappers (`connect_to_node/3` returning a
  #     `:gen_statem.call` result) and plain lookup helpers
  #     (`get_connection/3`).
  #
  # Together these cut the corpus's gen_statem findings from 108 (all
  # false) to the genuine dead-state cases.
  defp state_functions(module_data, exports, locally_called) do
    acting = action_returning(module_data.module, module_data.functions)

    Enum.filter(module_data.functions, fn {:function, name, arity, _entry, _instrs} ->
      arity == 3 and
        MapSet.member?(exports, {name, arity}) and
        not MapSet.member?(@non_state_callbacks, name) and
        not MapSet.member?(locally_called, {name, arity}) and
        MapSet.member?(acting, {name, arity})
    end)
  end

  defp extract_state_functions(facts, mod, module_data, exports, locally_called) do
    mod_str = inspect(mod)
    functions = module_data.functions
    state_funs = state_functions(module_data, exports, locally_called)

    # Register all states. In state_functions mode the state IS a
    # function — its ID is the natural site.
    facts =
      Enum.reduce(state_funs, facts, fn {:function, name, arity, _, _}, acc ->
        add_fact(acc, :statem_state, [
          mod_str,
          InstrId.name(name),
          InstrId.func_id(mod_str, name, arity)
        ])
      end)

    # Extract transitions and timeouts from each state function.
    facts =
      Enum.reduce(state_funs, facts, fn {:function, name, arity, _entry, instrs}, acc ->
        state_name = InstrId.name(name)
        # The module atom itself, not one re-read from its inspected name:
        # String.to_atom("A.B") is :"A.B", not A.B, and every site ID minted
        # from it was unresolvable.
        func_id = InstrId.func_id(mod, name, arity)

        acc
        |> extract_transitions(mod_str, state_name, instrs, func_id)
        |> extract_timeouts(mod_str, state_name, instrs, func_id)
        |> emit_event_clauses(mod_str, func_id, cfg(module_data, name, arity), instrs)
      end)

    state_set = MapSet.new(state_funs, fn {:function, name, arity, _, _} -> {name, arity} end)
    labels = function_labels(functions)

    Enum.reduce(functions, facts, fn {:function, name, arity, _, instrs} = function, acc ->
      acc =
        if MapSet.member?(state_set, {name, arity}),
          do: acc,
          else: helper_transitions(acc, mod, mod_str, function)

      returned_calls(acc, mod, mod_str, InstrId.func_id(mod, name, arity), instrs, labels)
    end)
  end

  # A function that is not a state function but returns a `next_state` or
  # `stop` action builds it for the state that called it (a Redix-style
  # `disconnect/3`, a lifted closure in a `reduce_while`): its target is
  # entered, and its caller may leave, from a state the graph does not
  # name. init/1's `{:ok, State, Data}` is read by extract_initial_states.
  defp helper_transitions(facts, mod, mod_str, {:function, name, arity, _entry, instrs}) do
    func_id = InstrId.func_id(mod, name, arity)
    ctx = synthetic_ctx(func_id)

    instrs
    |> return_shapes()
    |> Enum.reduce(facts, fn {_idx, elements}, acc ->
      case elements do
        [{:atom, :next_state}, target | _] ->
          to_state = resolve_element_value(target)

          acc
          |> track_dynamic(to_state, ctx, :statem_transition_target, :statem_helper_transition)
          |> add_fact(:statem_helper_transition, [mod_str, func_id, to_state])

        [{:atom, action} | _] when action in [:stop, :stop_and_reply] ->
          add_fact(acc, :statem_helper_transition, [mod_str, func_id, "stop"])

        _ ->
          acc
      end
    end)
  end

  # A function returning what a call returns hands the choice of its
  # action, and so of the state its caller leaves for, to the callee: a
  # tail call (a raise excepted), a call whose result reaches a return,
  # or a throw, which gen_statem takes as the callback's result. A local
  # callee is named so the rules can ask what it returns in turn;
  # anything else is dynamic.
  defp returned_calls(facts, mod, mod_str, func_id, instrs, labels) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {instr, idx} ->
      cond do
        throw_call?(instr) -> ["dynamic"]
        raise_call?(instr) -> []
        Instr.tail_call?(instr) -> [callee(instr, mod, labels)]
        Instr.call?(instr) and result_returned?(instrs, idx) -> [callee(instr, mod, labels)]
        true -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.reduce(facts, &add_fact(&2, :statem_returns_call, [mod_str, func_id, &1]))
  end

  defp callee(instr, mod, labels) do
    case local_call_target(instr, mod, labels) do
      {name, arity} -> InstrId.func_id(mod, name, arity)
      nil -> "dynamic"
    end
  end

  # A raise returns nothing: the compiler's own `{:badmap, _}` and
  # `{:case_clause, _}` exits end most map-updating functions with one,
  # and a state that crashes on a malformed event still never leaves.
  @raises [{:erlang, :error, 1}, {:erlang, :error, 2}, {:erlang, :error, 3}, {:erlang, :exit, 1}]

  defp raise_call?({op, _arity, {:extfunc, m, f, a}}) when op in [:call_ext, :call_ext_only],
    do: {m, f, a} in @raises

  defp raise_call?({:call_ext_last, _arity, {:extfunc, m, f, a}, _dealloc}),
    do: {m, f, a} in @raises

  defp raise_call?(_instr), do: false

  defp throw_call?({op, _arity, {:extfunc, :erlang, :throw, 1}})
       when op in [:call_ext, :call_ext_only],
       do: true

  defp throw_call?({:call_ext_last, _arity, {:extfunc, :erlang, :throw, 1}, _dealloc}), do: true
  defp throw_call?(_instr), do: false

  # Whether the value a call leaves in {x,0} is still there at a return
  # on the path that falls through (and the jumps it meets).
  defp result_returned?(instrs, idx) do
    returned(Enum.drop(instrs, idx + 1), [{:x, 0}], instrs, %{})
  end

  defp returned([], _holding, _instrs, _seen), do: false

  # `holding` is a list: a MapSet is opaque to dialyzer across the
  # recursion.
  defp returned([instr | rest], holding, instrs, seen) do
    cond do
      holding == [] ->
        false

      instr == :return ->
        {:x, 0} in holding

      match?({:jump, {:f, _}}, instr) ->
        {:jump, {:f, label}} = instr

        not Map.has_key?(seen, label) and
          returned(
            instructions_from_label(instrs, label),
            holding,
            instrs,
            Map.put(seen, label, true)
          )

      not Instr.falls_through?(instr) ->
        false

      true ->
        returned(rest, Instr.carry(instr, holding), instrs, seen)
    end
  end

  defp emit_event_clauses(facts, mod_str, func_id, fun, instrs) do
    clauses = EventClauses.analyse(fun, instrs)

    facts =
      Enum.reduce(clauses.event_types, facts, fn type, acc ->
        add_fact(acc, :statem_event_clause, [mod_str, func_id, type])
      end)

    facts =
      if clauses.info_catchall?,
        do: add_fact(facts, :statem_info_catchall, [mod_str, func_id]),
        else: facts

    facts =
      if clauses.event_catchall?,
        do: add_fact(facts, :statem_event_catchall, [mod_str, func_id]),
        else: facts

    # What the content is compared to, and which clauses take it by
    # shape alone: what an :info message sent to the machine meets.
    facts =
      instrs
      |> Dispatch.compared_atoms(:any)
      |> Enum.reduce(facts, &add_fact(&2, :statem_info_tag, [mod_str, func_id, inspect(&1)]))

    facts =
      instrs
      |> MessageClauses.open_shapes({:x, 1})
      |> Enum.reduce(facts, &add_fact(&2, :statem_info_open, [mod_str, func_id, to_string(&1)]))

    Enum.reduce(CallClauses.analyse(fun, instrs), facts, fn {idx, tag}, acc ->
      add_fact(acc, :statem_call_unreplied, [mod_str, func_id, InstrId.mint(func_id, idx), tag])
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

  # The functions that return a gen_statem action: in their own body, or
  # as the result of a local function that does (a tail call, a call
  # whose result reaches a return).
  defp action_returning(mod, functions) do
    labels = function_labels(functions)

    direct =
      for {:function, name, arity, _e, instrs} <- functions,
          returns_statem_action?(instrs),
          into: MapSet.new(),
          do: {name, arity}

    returned =
      for {:function, name, arity, _e, instrs} <- functions,
          into: %{},
          do: {{name, arity}, returned_locals(instrs, mod, labels)}

    grow_acting(direct, returned)
  end

  defp grow_acting(acting, returned) do
    grown =
      for {fa, callees} <- returned,
          not MapSet.member?(acting, fa),
          Enum.any?(callees, &MapSet.member?(acting, &1)),
          into: acting,
          do: fa

    if MapSet.size(grown) == MapSet.size(acting), do: acting, else: grow_acting(grown, returned)
  end

  defp returned_locals(instrs, mod, labels) do
    for {instr, idx} <- Enum.with_index(instrs),
        not raise_call?(instr),
        Instr.tail_call?(instr) or (Instr.call?(instr) and result_returned?(instrs, idx)),
        fa = local_call_target(instr, mod, labels),
        fa != nil,
        uniq: true,
        do: fa
  end

  defp returns_statem_action?(instrs) do
    tuple_action_return?(instrs) or bare_action_return?(instrs)
  end

  defp tuple_action_return?(instrs) do
    instrs
    |> return_shapes()
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
  defp extract_handle_event(facts, mod_str, module_data) do
    case find_function(module_data.functions, :handle_event, 4) do
      nil ->
        facts

      instrs ->
        facts
        |> extract_transitions(mod_str, "handle_event", instrs, "#{mod_str}:handle_event/4")
        |> extract_timeouts(mod_str, "handle_event", instrs, "#{mod_str}:handle_event/4")
        |> emit_event_clauses(
          mod_str,
          "#{mod_str}:handle_event/4",
          cfg(module_data, :handle_event, 4),
          instrs
        )
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
    |> return_shapes()
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
      {{:put_tuple2, dst, {:list, elements}}, idx}, acc ->
        acc
        |> maybe_timeout_tuple(mod_str, state_name, elements, ctx, {instrs, idx, dst})
        |> extract_timeouts_from_elements(mod_str, state_name, elements)

      {{:move, {:literal, actions}, _}, _idx}, acc when is_list(actions) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, actions)

      # A single fully-literal action, `{{:timeout, :backoff}, 500, nil}`.
      {{:move, {:literal, action}, _}, _idx}, acc when is_tuple(action) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, [action])

      _, acc ->
        acc
    end)
  end

  # Check if this put_tuple2 is itself a timeout ACTION: a 3-tuple headed
  # :timeout, :state_timeout or {:timeout, name} that flows into the
  # callback's return. A `{:timeout, ref, payload}` built to send, or the
  # `{:timeout, name}` inside a generic timeout `{{:timeout, name}, ms,
  # content}`, is not an armed event timeout (DBConnection.Connection,
  # Finch.HTTP2.Pool); the generic timeout itself is
  # (Postgrex.ReplicationConnection's reconnect backoff).
  defp maybe_timeout_tuple(
         facts,
         mod_str,
         state_name,
         [{:literal, {:timeout, name}}, timeout_val, _content],
         ctx,
         {instrs, idx, dst}
       )
       when is_atom(name) do
    if flows_to_return?(instrs, idx, dst) do
      value = resolve_element_value(timeout_val)

      facts
      |> track_dynamic(value, ctx, :statem_timeout_value, :statem_timeout)
      |> add_fact(:statem_timeout, [mod_str, state_name, "generic", value])
    else
      facts
    end
  end

  defp maybe_timeout_tuple(
         facts,
         mod_str,
         state_name,
         [{:atom, :state_timeout}, timeout_val, _content],
         ctx,
         {instrs, idx, dst}
       ) do
    if flows_to_return?(instrs, idx, dst) do
      value = resolve_element_value(timeout_val)

      facts
      |> track_dynamic(value, ctx, :statem_timeout_value, :statem_timeout)
      |> add_fact(:statem_timeout, [mod_str, state_name, "state_timeout", value])
    else
      facts
    end
  end

  defp maybe_timeout_tuple(
         facts,
         mod_str,
         state_name,
         [{:atom, :timeout}, timeout_val, _content],
         ctx,
         {instrs, idx, dst}
       ) do
    if flows_to_return?(instrs, idx, dst) do
      value = resolve_element_value(timeout_val)

      facts
      |> track_dynamic(value, ctx, :statem_timeout_value, :statem_timeout)
      |> add_fact(:statem_timeout, [mod_str, state_name, "event_timeout", value])
    else
      facts
    end
  end

  defp maybe_timeout_tuple(facts, _mod_str, _state_name, _elements, _ctx, _site), do: facts

  @return_heads [:keep_state, :keep_state_and_data, :next_state, :repeat_state, :ok, :stop]

  # Whether the tuple built at `idx` becomes (part of) the callback's
  # return: put into a state-return tuple, into an action list that is,
  # or moved to x0 before a return. Handed to a call instead, it is a
  # message or an argument, not an action. The walk follows the path that
  # falls through and the jumps it meets (the compiler shares a return
  # block between clauses); every other register effect is
  # `Argus.Instr.carry/2`'s.
  defp flows_to_return?(instrs, idx, dst) do
    case Instr.register(dst) do
      {kind, _} = reg when kind in [:x, :y] ->
        flow(Enum.drop(instrs, idx + 1), MapSet.new([reg]), instrs, %{}) == :returns

      _ ->
        false
    end
  end

  defp flow([], _aliases, _instrs, _seen), do: :no

  defp flow([instr | rest], aliases, instrs, seen) do
    case flow_step(instr, aliases) do
      {:cont, aliases} ->
        flow(rest, aliases, instrs, seen)

      {:jump, label} ->
        if Map.has_key?(seen, label),
          do: :no,
          else:
            flow(
              instructions_from_label(instrs, label),
              aliases,
              instrs,
              Map.put(seen, label, true)
            )

      {:halt, result} ->
        result
    end
  end

  # One instruction along the tuple's flow: `aliases` are the registers
  # holding it or a structure containing it.
  defp flow_step({:put_tuple2, d, {:list, [{:atom, head} | rest] = elements}}, aliases) do
    if head in @return_heads and any_alias?(rest, aliases),
      do: {:halt, :returns},
      else: {:cont, alias_if(aliases, any_alias?(elements, aliases), d)}
  end

  defp flow_step({:put_tuple2, d, {:list, elements}}, aliases),
    do: {:cont, alias_if(aliases, any_alias?(elements, aliases), d)}

  defp flow_step({:put_list, head, tail, d}, aliases),
    do: {:cont, alias_if(aliases, any_alias?([head, tail], aliases), d)}

  defp flow_step(:return, aliases),
    do: {:halt, if(MapSet.member?(aliases, {:x, 0}), do: :returns, else: :no)}

  defp flow_step({:jump, {:f, label}}, _aliases), do: {:jump, label}

  # Passed to a call, the tuple is a message or an argument, not an
  # action; any other instruction moves, keeps or overwrites it as
  # Argus.Instr says, and one that does not fall through ends the path.
  defp flow_step(instr, aliases) do
    cond do
      Instr.call?(instr) and any_alias?(Instr.uses(instr), aliases) ->
        {:halt, :no}

      not Instr.falls_through?(instr) ->
        {:halt, :no}

      true ->
        {:cont, MapSet.new(Instr.carry(instr, aliases))}
    end
  end

  defp any_alias?(operands, aliases),
    do: Enum.any?(operands, &MapSet.member?(aliases, Instr.register(&1)))

  defp alias_if(aliases, true, d), do: MapSet.put(aliases, Instr.register(d))
  defp alias_if(aliases, false, d), do: MapSet.delete(aliases, Instr.register(d))

  # Scan literal elements inside a put_tuple2 for action lists containing timeouts.
  defp extract_timeouts_from_elements(facts, mod_str, state_name, elements) do
    Enum.reduce(elements, facts, fn
      {:literal, actions}, acc when is_list(actions) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, actions)

      {:literal, action}, acc when is_tuple(action) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, [action])

      _, acc ->
        acc
    end)
  end

  defp extract_timeouts_from_literal_actions(facts, mod_str, state_name, actions) do
    actions
    |> list_elements()
    |> Enum.reduce(facts, fn
      {:state_timeout, value, _}, acc ->
        add_fact(acc, :statem_timeout, [mod_str, state_name, "state_timeout", timeout(value)])

      {:timeout, value, _}, acc ->
        add_fact(acc, :statem_timeout, [mod_str, state_name, "event_timeout", timeout(value)])

      # A generic timeout is headed by {:timeout, name}; a 3-tuple with an
      # atom head is another action ({:next_event, :internal, :connect}).
      {{:timeout, name}, value, _}, acc when is_atom(name) ->
        add_fact(acc, :statem_timeout, [mod_str, state_name, "generic", timeout(value)])

      _, acc ->
        acc
    end)
  end

  # A timeout is milliseconds or `:infinity`; anything else in that place
  # is a literal the action would reject, and names no time.
  defp timeout(value) when is_integer(value) or is_atom(value), do: to_string(value)
  defp timeout(_value), do: "dynamic"

  defp resolve_element_value({:atom, a}), do: to_string(a)
  defp resolve_element_value({:integer, n}), do: to_string(n)
  defp resolve_element_value({:literal, v}) when is_atom(v), do: to_string(v)
  defp resolve_element_value({:literal, v}) when is_integer(v), do: to_string(v)
  defp resolve_element_value(_), do: "dynamic"
end
