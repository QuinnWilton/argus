defmodule Argus.Schema.GenStatem do
  @moduledoc """
  Layer-2 gen_statem facts: states, transitions, timeouts, and handled event types. \
  Exposed through `Argus.Schema`.
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
          {:clause, :symbol,
           "the tag of func's clause on the paths to it (clause_call's spelling), `*` for none"},
          {:type, :symbol, "the inserted event's type as a clause head tells it, `*` unspelled"},
          {:content, :symbol,
           "the inserted event's content as a clause head tells it (its atom, or a tuple's), " <>
             "`*` unspelled"}
        ],
        doc: """
        A constructed or literal `{:next_event, type, content}` action, whether returned \
        or not. These events run before mailbox messages and are the source of \
        `:internal` events. `{:call, from}` uses type `:call`; unresolved type or \
        content uses `*`. Recorded per clause, using event type/content tags in event \
        functions, for `clientlib/runs.dl`.
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
        A literal initial state returned by `init/1`, one row per resolvable clause. \
        Computed states have no row. Gives reachability analysis an explicit entry \
        state.
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
        A helper's `next_state` or `stop` return on behalf of an unresolved caller \
        state. `keep_state` is omitted because it represents the caller's self-loop.
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
        A function of a `state_functions` machine that may return a callee's result. \
        Local calls name the callee; remote calls, applies, and throws use `dynamic`. \
        gen_statem treats a thrown value as the callback result.
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
        A possible event type handled by a gen_statem callback. Counts every comparison \
        of the first argument, so consumers use it to check for missing handlers.
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
        A non-catch-all clause accepting gen_statem event content by shape without \
        testing its value or tag. Equivalent to `callback_open` for the content register \
        `{x, 1}`.
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
        An atom compared anywhere in a gen_statem callback. Over-approximates content \
        tags among event types and state names; consumers check for missing tags.
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
        A gen_statem clause accepting any content for `:info`. After establishing that \
        event type, its body is reachable without a successful test on another register.
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
