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

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      find_function: 3,
      get_behaviours: 1,
      scan_return_tuples: 1
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

  # Atoms that appear in gen_statem bytecode but are event types, protocol
  # atoms, or common result atoms — not state names. Filtering these
  # reduces false positives in handle_event_function mode where we can't
  # easily distinguish state-argument matches from event-type matches.
  # Atoms that appear in gen_statem bytecode but are event types, protocol
  # atoms, or common result atoms — not state names. Filtering these
  # reduces false positives in handle_event_function mode where we can't
  # easily distinguish state-argument matches from event-type matches.
  @non_state_atoms MapSet.new([
                     # Event types.
                     :cast,
                     :call,
                     :info,
                     :internal,
                     :timeout,
                     :state_timeout,
                     :event_timeout,
                     :"$gen_call",
                     :"$gen_cast",
                     # Result/control atoms.
                     :ok,
                     :error,
                     true,
                     false,
                     :undefined,
                     :noreply,
                     :reply,
                     :stop,
                     :normal,
                     :shutdown,
                     :hibernate,
                     :postpone,
                     :keep_state,
                     :keep_state_and_data,
                     :next_state,
                     :next_event,
                     # Transport / protocol atoms common in connection state machines.
                     :tcp,
                     :tcp_closed,
                     :tcp_error,
                     :ssl,
                     :ssl_closed,
                     :ssl_error,
                     :http,
                     :http2,
                     # Common non-state atoms.
                     :no_state,
                     :backoff
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

    callback_mode = detect_callback_mode(functions)

    facts = add_fact(%{}, :statem_module, [mod_str, to_string(callback_mode)])

    case callback_mode do
      :state_functions ->
        extract_state_functions(facts, mod_str, functions)

      :handle_event_function ->
        extract_handle_event(facts, mod_str, functions)

      :unknown ->
        facts
    end
  end

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

  # In state_functions mode, each 3-arity exported function whose name isn't
  # a standard callback is a state handler.
  defp extract_state_functions(facts, mod_str, functions) do
    state_funs =
      Enum.filter(functions, fn {:function, name, arity, _entry, _instrs} ->
        arity == 3 and not MapSet.member?(@non_state_callbacks, name)
      end)

    # Register all states.
    facts =
      Enum.reduce(state_funs, facts, fn {:function, name, _, _, _}, acc ->
        add_fact(acc, :statem_state, [mod_str, to_string(name)])
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

  # In handle_event_function mode, analyze handle_event/4 for state patterns.
  defp extract_handle_event(facts, mod_str, functions) do
    case find_function(functions, :handle_event, 4) do
      nil ->
        facts

      instrs ->
        # Look for state atoms in pattern matches and transitions.
        facts
        |> extract_states_from_instrs(mod_str, instrs)
        |> extract_transitions(mod_str, "handle_event", instrs, "#{mod_str}:handle_event/4")
        |> extract_timeouts(mod_str, "handle_event", instrs, "#{mod_str}:handle_event/4")
    end
  end

  # Extract state atoms from instructions — looks for atom comparisons
  # and select_val patterns that indicate state matching. Filters out
  # known non-state atoms (event types, protocol atoms) to reduce FPs.
  defp extract_states_from_instrs(facts, mod_str, instrs) do
    Enum.reduce(instrs, facts, fn
      {:select_val, _, _, {:list, pairs}}, acc ->
        pairs
        |> Enum.take_every(2)
        |> Enum.reduce(acc, fn
          {:atom, state}, inner_acc ->
            if state_candidate?(state) do
              add_fact(inner_acc, :statem_state, [mod_str, to_string(state)])
            else
              inner_acc
            end

          _, inner_acc ->
            inner_acc
        end)

      {:test, :is_eq_exact, _, [{:x, _}, {:atom, state}]}, acc ->
        if state_candidate?(state) do
          add_fact(acc, :statem_state, [mod_str, to_string(state)])
        else
          acc
        end

      {:test, :is_eq_exact, _, [{:atom, state}, {:x, _}]}, acc ->
        if state_candidate?(state) do
          add_fact(acc, :statem_state, [mod_str, to_string(state)])
        else
          acc
        end

      _, acc ->
        acc
    end)
  end

  defp state_candidate?(atom) do
    is_atom(atom) and atom != nil and atom != :"" and
      not MapSet.member?(@non_state_atoms, atom)
  end

  # Extract transitions from return tuples. Look for {:next_state, target, ...}
  # patterns in put_tuple2 instructions.
  defp extract_transitions(facts, mod_str, from_state, instrs, _func_id) do
    return_tuples = scan_return_tuples(instrs)

    Enum.reduce(return_tuples, facts, fn {_idx, elements}, acc ->
      case elements do
        # {:next_state, target_state, data} or {:next_state, target_state, data, actions}.
        [{:atom, :next_state}, target | _] ->
          to_state = resolve_element_value(target)

          acc
          |> add_fact(:statem_transition, [mod_str, from_state, "event", to_state])
          |> maybe_add_target_state(mod_str, to_state)

        # {:keep_state, ...} — self-transition.
        [{:atom, :keep_state} | _] ->
          add_fact(acc, :statem_transition, [mod_str, from_state, "event", from_state])

        # {:keep_state_and_data, ...} — self-transition.
        [{:atom, :keep_state_and_data} | _] ->
          add_fact(acc, :statem_transition, [mod_str, from_state, "event", from_state])

        # {:stop, ...} — terminal transition.
        [{:atom, :stop} | _] ->
          add_fact(acc, :statem_transition, [mod_str, from_state, "event", "stop"])

        _ ->
          acc
      end
    end)
  end

  # Also scan for literal return values moved to x0.
  defp maybe_add_target_state(facts, mod_str, to_state) do
    if to_state != "dynamic" and to_state != "stop" do
      add_fact(facts, :statem_state, [mod_str, to_state])
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
  defp extract_timeouts(facts, mod_str, state_name, instrs, _func_id) do
    instrs
    |> Enum.with_index()
    |> Enum.reduce(facts, fn
      {{:put_tuple2, _, {:list, elements}}, _idx}, acc ->
        acc
        |> maybe_timeout_tuple(mod_str, state_name, elements)
        |> extract_timeouts_from_elements(mod_str, state_name, elements)

      {{:move, {:literal, actions}, _}, _idx}, acc when is_list(actions) ->
        extract_timeouts_from_literal_actions(acc, mod_str, state_name, actions)

      _, acc ->
        acc
    end)
  end

  # Check if this put_tuple2 is itself a timeout tuple.
  defp maybe_timeout_tuple(facts, mod_str, state_name, [{:atom, :state_timeout}, timeout_val | _]) do
    value = resolve_element_value(timeout_val)
    add_fact(facts, :statem_timeout, [mod_str, state_name, "state_timeout", value])
  end

  defp maybe_timeout_tuple(facts, mod_str, state_name, [{:atom, :timeout}, timeout_val | _]) do
    value = resolve_element_value(timeout_val)
    add_fact(facts, :statem_timeout, [mod_str, state_name, "event_timeout", value])
  end

  defp maybe_timeout_tuple(facts, _mod_str, _state_name, _elements), do: facts

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
