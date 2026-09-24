defmodule Argus.Schema.GenStatem do
  @moduledoc """
  gen_statem machines: their states, transitions and timeouts, and the
  events their clauses handle.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    [
      %{
        name: :statem_module,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:callback_mode, :symbol, "state_functions or handle_event_function"}
        ],
        doc: "Module implementing gen_statem behaviour."
      },
      %{
        name: :statem_state,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:state, :symbol, "state atom"},
          {:site, :symbol,
           "where the state was found: the state function's ID in state_functions " <>
             "mode, the matching instruction in handle_event mode"}
        ],
        doc: "State in a gen_statem state machine."
      },
      %{
        name: :statem_initial,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:state, :symbol, "initial state atom"}
        ],
        doc: """
        Initial state declared by `init/1`'s `{:ok, State, Data}` return \
        (one row per resolvable clause — a machine with multiple init clauses \
        has several). Read directly from the return rather than inferred \
        topologically, so the reachability analysis knows which no-incoming \
        state is the legitimate entry point. Only literal-atom states are \
        recorded; a computed initial state emits no row.
        """
      },
      %{
        name: :statem_transition,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:from_state, :symbol, "source state"},
          {:event, :symbol, "event type"},
          {:to_state, :symbol, "target state"}
        ],
        doc: "State transition in a gen_statem."
      },
      %{
        name: :statem_timeout,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:state, :symbol, "state setting the timeout"},
          {:type, :symbol, "timeout type (state_timeout, event_timeout, generic)"},
          {:value, :symbol, "timeout value"}
        ],
        doc: "Timeout set in a gen_statem state."
      },
      %{
        name: :statem_event_clause,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the state function or handle_event/4"},
          {:event_type, :symbol,
           "a literal event type a clause head compares the first argument to: " <>
             "'info', 'cast', 'timeout', 'state_timeout', ..., or '{call}' / '{timeout}' for tagged tuples"}
        ],
        doc: """
        A gen_statem callback has a clause for this event type. Over-approximated \
        the same way callback_tag is — every comparison of the first argument \
        counts — so consumers ask which types are NOT handled.
        """
      },
      %{
        name: :statem_call_unreplied,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the state function or handle_event/4"},
          {:site, :instr_id, "the clause's last pattern test, or its return when it passed none"},
          {:tag, :symbol,
           "the literal that test compares against, as inspect/1 spells it (':cancel'), else empty"}
        ],
        doc:
          "A {:call, from} clause returns without a reply action, without " <>
            "postponing, and without keeping `from`: the caller stays blocked. " <>
            "Pattern tests carry the previous clause's line, so `tag` is what a " <>
            "consumer with the source finds the clause head by."
      },
      %{
        name: :statem_info_open,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the state function or handle_event/4"},
          {:shape, :symbol, "'any' | 'tuple'"}
        ],
        doc: """
        Some clause other than a catch-all takes the event content by its \
        shape alone, never comparing it or its tag to a value — \
        `callback_open` for a gen_statem's content, `{x, 1}`.
        """
      },
      %{
        name: :statem_info_tag,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the state function or handle_event/4"},
          {:tag, :symbol, "an atom the callback compares anything to"}
        ],
        doc: """
        An atom the callback compares somewhere — an event content's tag \
        among the event types and state names. Over-approximated as \
        `callback_tag` is: a rule asks whether a tag is NOT taken.
        """
      },
      %{
        name: :statem_info_catchall,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the state function or handle_event/4"}
        ],
        doc: """
        Some clause of the callback accepts an :info event with any content: \
        from a test establishing the event type is :info, a body is reachable \
        without passing the success branch of a test on any other register.
        """
      },
      %{
        name: :statem_event_catchall,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the state function or handle_event/4"}
        ],
        doc:
          "Some clause of the callback accepts any event: a body is reachable from the entry by failure branches alone."
      }
    ]
  end
end
