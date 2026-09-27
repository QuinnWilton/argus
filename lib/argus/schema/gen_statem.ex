defmodule Argus.Schema.GenStatem do
  @moduledoc """
  gen_statem machines: their states, transitions and timeouts, and the
  events their clauses handle.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
        name: :statem_insert,
        layer: 2,
        fields: [
          {:id, :symbol, "where the action tuple is built or held"},
          {:func, :symbol, "the function holding it"},
          {:clause, :symbol, "the tag of func's first argument on the paths to it, `*` for none"},
          {:type, :symbol, "the inserted event's type as a clause head tells it, `*` unspelled"}
        ],
        doc: """
        A `{:next_event, type, content}` action in a function of a \
        gen_statem's module: an event the machine runs before anything in \
        its mailbox, and the only way an event of type `:internal` is made. \
        Read where the tuple is built or where a literal holds it \
        (`[{:next_event, :internal, :go}]`), whether or not it is returned. \
        `{:call, from}` is spelled by its tag, `:call`; a type the function \
        does not spell (a parameter) is `*`. One row per clause of `func`, \
        by its first argument's tag (`Argus.Extractor.Dispatch.argument_tags/2`). \
        What enters a gen_statem's `:internal` clauses, for \
        `clientlib/runs.dl`'s once clauses.
        """
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
        name: :statem_helper_transition,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "the function that returns it, not a state function"},
          {:to_state, :symbol, "target state, `stop`, or `dynamic` when computed"}
        ],
        doc: """
        A transition a function that is not a state function returns on \
        some state's behalf (a `disconnect/2` helper returning \
        `{:next_state, :disconnected, data}`): a way into its target from \
        a state the extractor does not name. Only `next_state` and `stop` \
        returns are recorded; a helper's `keep_state` is its caller's \
        self-loop.
        """
      },
      %{
        name: :statem_returns_call,
        layer: 2,
        fields: [
          {:mod, :symbol, "module name"},
          {:func, :symbol, "a function of a state_functions machine"},
          {:callee, :symbol, "the local function whose result it returns, or `dynamic`"}
        ],
        doc: """
        A function of a `state_functions` machine that may return what a \
        call returns: a tail call, a call whose result reaches a return, \
        or a throw (which gen_statem takes as the callback's result, \
        `dynamic`). The callee is the local function called, or `dynamic` \
        for a remote, applied or thrown value: the action it returns, and \
        so the state it leaves for, is the callee's.
        """
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
    ])
  end
end
