defmodule Argus.Schema.Callbacks do
  @moduledoc """
  Layer-2 callback facts: handled message tags, catch-all clauses, and transitions from \
  `init/1` to `handle_continue/2`. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :callback_tag,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"},
          {:tag, :symbol, "an atom the callback discriminates on"}
        ],
        doc: """
        A possible message tag handled by a callback. Counts every atom comparison in \
        the body without tracking registers. This over-approximation is safe for rules \
        that report missing handlers: extra tags suppress findings.
        """
      },
      %{
        name: :callback_tag_shape,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"},
          {:tag, :symbol, "an atom a clause head compares the message, or its tag, with"},
          {:arity, :number,
           "0 when the message is the atom, the tuple's size when it is its tag, -1 when that size is not known"}
        ],
        doc: """
        A callback clause's message shape: atom `tag` with arity 0, or a tuple of the \
        given arity headed by `tag`. Reads clause heads only, unlike `callback_tag`, so \
        an atom handler does not count as a handler for a tuple with that tag.
        """
      },
      %{
        name: :callback_takes_down,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"},
          {:type, :symbol, "'process' | 'port' | 'any': the monitor type the clause takes"}
        ],
        doc: """
        A callback clause handling all `:DOWN` reasons for a monitor type: `any` or \
        `process`. Reference, object, and state restrictions are allowed; reason \
        restrictions are not \
        (`Argus.Extractors.CallbackTag.MessageClauses.takes_down/2`).
        """
      },
      %{
        name: :callback_takes_exit,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"}
        ],
        doc: """
        A callback clause handling trapped `:EXIT` messages for every exit reason. \
        Sender and state restrictions are allowed; reason restrictions are not \
        (`Argus.Extractors.CallbackTag.MessageClauses.takes_exit?/2`).
        """
      },
      %{
        name: :callback_drops,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"}
        ],
        doc: """
        A catch-all that only logs or ignores the message. All uses of the message or \
        derived values must go to Logger, `:logger`, IO, or `inspect/2`. Testing, \
        returning, storing, or otherwise passing the message disqualifies it.
        """
      },
      %{
        name: :callback_open,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"},
          {:shape, :symbol, "'any' | 'tuple'"},
          {:arity, :number, "a tuple's arity where the head tests it, else -1"}
        ],
        doc: """
        A non-catch-all clause accepting messages by shape without comparing their value \
        or tag. Records `any` or `tuple` with arity, including `{ref, result}` guarded \
        by `is_reference(ref)`. Complements `callback_tag` when checking whether a \
        message is handled.
        """
      },
      %{
        name: :callback_total,
        layer: 2,
        fields: [
          {:func, :symbol, "the callback"},
          {:callback, :symbol, "'handle_call' | 'handle_cast' | 'handle_info'"}
        ],
        doc: """
        An unguarded catch-all, established by the absence of branches to the function's \
        `func_info` failure label. Every input matches; guarded catch-alls do not \
        qualify.
        """
      },
      %{
        name: :param_decided,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:func, :symbol, "the function containing it"},
          {:pos, :number, "0-based position of the parameter the deciding test reads"}
        ],
        doc: """
        A call, subscription, or monitor controlled by a test on parameter `pos`, one of \
        its fields, or a call result derived from it (`Argus.Extractors.LiveView`). \
        Tests whose alternative paths only raise do not count. For a state parameter, \
        this identifies state-dependent calls.
        """
      },
      %{
        name: :clause_call,
        layer: 2,
        fields: [
          {:id, :symbol, "a call"},
          {:func, :symbol, "the function holding it"},
          {:tag, :symbol, "the inspected tag its first argument is established to be"}
        ],
        doc: """
        A call or send reached only when the first argument has `tag`, either as an atom \
        or tuple head. Every path must establish a tag; one row is emitted per possible \
        tag. Enables clause-specific call-chain analysis. gen_statem event functions use \
        `"<type> <content>"`, or the type alone when content is unknown; `clause_event` \
        splits these tags.
        """
      },
      %{
        name: :clause_event,
        layer: 2,
        fields: [
          {:func, :symbol, "a gen_statem event function"},
          {:tag, :symbol, "one of its two-part clause tags"},
          {:type, :symbol, "the tag's event type, inspected (`:internal`, `:info`, `:call`)"},
          {:content, :symbol, "the tag's content, inspected (`:connect`, `:DOWN`)"}
        ],
        doc: """
        The type and content of a gen_statem clause tag used by `clause_call`, \
        `returned_update`, and `statem_insert`. Content is an atom or tuple head, \
        allowing rules to identify events such as `:info :DOWN`.
        """
      },
      %{
        name: :info_clause_always,
        layer: 2,
        fields: [
          {:id, :symbol, "a call, or an Erlang send"},
          {:func, :symbol, "the handle_info/2 holding it"},
          {:tag, :symbol, "the inspected atom the clause takes"}
        ],
        doc: """
        A call that every continuing path through a `handle_info/2` clause for atom \
        `tag` must execute. Excludes `{:stop, ...}` returns. Distinguishes timers \
        rearmed on every iteration from retries rearmed on only some branches. Computed \
        for atom tags only.
        """
      },
      %{
        name: :shutdown_chooses,
        layer: 2,
        fields: [
          {:func, :symbol, "a function"},
          {:pos, :number, "0-based position of the parameter it chooses by"}
        ],
        doc: """
        A function with calls excluded when parameter `pos` is `:shutdown`. The \
        extractor walks every path with that parameter fixed; unreadable tests retain \
        all reachable calls (`Argus.Extractor.Dispatch.reached_holding/3`). No row means \
        no call is excluded for that parameter.
        """
      },
      %{
        name: :shutdown_runs,
        layer: 2,
        fields: [
          {:id, :symbol, "a call, or Erlang's `!`"},
          {:func, :symbol, "the function holding it"},
          {:pos, :number, "0-based position of a parameter `func` chooses by"}
        ],
        doc: """
        A call reachable with parameter `pos` fixed to `:shutdown`, for a function in \
        `shutdown_chooses`. Calls without rows are unreachable under that value.
        """
      },
      %{
        name: :shutdown_handed,
        layer: 2,
        fields: [
          {:id, :symbol, "a call"},
          {:func, :symbol, "the function holding it"},
          {:pos, :number, "0-based position of `func`'s parameter holding `:shutdown`"},
          {:arg, :number, "0-based position of the callee's argument it lands in"}
        ],
        doc: """
        A call reachable with parameter `pos` equal to `:shutdown` that forwards it \
        unchanged to argument `arg` on every reaching path. Runtime calls are excluded.
        """
      },
      %{
        name: :init_continues_to,
        layer: 2,
        fields: [
          {:mod, :symbol, "module whose init/1 (or any handler) returns {:continue, _}"},
          {:tag, :symbol, "the continue tag (inspected atom or 'dynamic')"}
        ],
        doc: """
        A GenServer return scheduling `handle_continue/2` from `init/1` or a handler. \
        Used to identify deferred work reachable during startup.
        """
      },
      %{
        name: :handle_continue_clause,
        layer: 2,
        fields: [
          {:mod, :symbol, "module containing the handle_continue clause"},
          {:tag, :symbol, "the matched continue tag (inspected atom or 'dynamic')"},
          {:func_id, :symbol, "function ID of the clause"}
        ],
        doc: """
        A module's `handle_continue(tag, _)` clause. Paired with `init_continues_to` to \
        identify continuation bodies reachable from init.
        """
      },
      %{
        name: :continue_return,
        layer: 2,
        fields: [
          {:id, :symbol, "the return"},
          {:func, :symbol, "the function holding it"},
          {:clause, :symbol,
           "the tag of func's first argument on the paths to the return, `*` for none"},
          {:tag, :symbol, "the continue term's atom or tuple tag, `*` when not spelled"}
        ],
        doc: """
        A return scheduling `handle_continue/2` from init, a handler, or a returned \
        helper result. `tag` is the continuation atom or tuple head. One row per \
        enclosing first-argument clause tag, used by `clientlib/runs.dl` to identify \
        continuations that run once.
        """
      },
      %{
        name: :timeout_return,
        layer: 2,
        fields: [
          {:id, :symbol, "the return"},
          {:func, :symbol, "the function holding it"},
          {:clause, :symbol,
           "the tag of func's first argument on the paths to the return, `*` for none"}
        ],
        doc: """
        A return arming a callback's idle timeout, including unresolved timeout values. \
        Excludes `:infinity`, `:hibernate`, and continuations. The runtime sends \
        `:timeout` only if no other message arrives first. Recorded in helpers as well \
        as callbacks, once per enclosing clause; unlike `callback_timeout`, does not \
        require a literal integer.
        """
      },
      %{
        name: :start_acked,
        layer: 2,
        fields: [
          {:id, :symbol, "a call or a receive's loop_rec"},
          {:func, :symbol, "the function holding it"}
        ],
        doc: """
        A call or receive dominated by `:proc_lib.init_ack/1,2` in the same function. \
        The starter is released before this site, so later waits belong to the running \
        process rather than startup. Acknowledgements in helpers are not detected.
        """
      },
      %{
        name: :state_gate,
        layer: 2,
        fields: [
          {:site, :symbol, "a call or send"},
          {:func, :symbol, "the handler holding it"},
          {:key, :symbol,
           "the inspected map key, or an Erlang record's field as its 0-based tuple position ({2})"},
          {:value, :symbol, "an atom the field holds when the site runs, inspected"}
        ],
        doc: """
        A GenServer handler call or send allowed only when input state field `key` holds \
        one of the recorded atom values. Every reaching path must enforce the \
        restriction. Nested fields, fields read via calls, and `__struct__` are excluded \
        (`Argus.Extractors.StateGate`).
        """
      },
      %{
        name: :gate_closed,
        layer: 2,
        fields: [
          {:site, :symbol, "a gated call or send (state_gate)"},
          {:func, :symbol, "the handler holding it"},
          {:key, :symbol, "the gated field, as state_gate spells it"}
        ],
        doc: """
        Every completion after `site` either stops the process or returns state that \
        excludes all values admitted by the site's `state_gate` rows. Includes \
        local-helper returns and try handlers. Unchanged or unresolved state does not \
        close the gate; neither does `throw`, whose value GenServer uses as the callback \
        result.
        """
      },
      %{
        name: :state_excluded,
        layer: 2,
        fields: [
          {:site, :symbol, "a call or send"},
          {:func, :symbol, "the handler holding it"},
          {:key, :symbol, "the field, as state_gate spells it"},
          {:value, :symbol, "an atom the field holds when the site does not run, inspected"}
        ],
        doc: """
        A GenServer handler call or send unreachable when input state field `key` equals \
        atom `value`, but reachable for another value (`Argus.Extractors.StateGate`).
        """
      },
      %{
        name: :acquired_if_absent,
        layer: 2,
        fields: [
          {:site, :symbol, "a call (or send)"},
          {:func, :symbol, "the function holding it"},
          {:pos, :number, "the parameter whose field the store is, -1 for a named table"},
          {:store, :symbol, "the field, as returned_update spells it, or `table :name`"},
          {:arg, :number, "which of the site's arguments is the key the test asked about"}
        ],
        doc: """
        A call reached only when a membership test or lookup finds its argument `arg` \
        absent from `store`. The absent path reaches the site; the present path does not \
        (`Argus.Extractors.StateGate.Absent`). Repeating the acquisition requires \
        removing its key from the store.
        """
      },
      %{
        name: :state_return,
        layer: 2,
        fields: [
          {:func, :symbol, "a GenServer handler, code_change/3 or init/1"},
          {:clause, :symbol,
           "the tag of func's first argument on the paths to the return, `*` for none"},
          {:key, :symbol, "a field some state_gate or state_excluded row of the module names"},
          {:value, :symbol,
           "the literal it is set to, inspected; 'nonatom' for a value no atom is; " <>
             "'dynamic' for any value, or a state the return does not show"}
        ],
        doc: """
        A possible returned value for state field `key` in clause `clause`, including \
        init, handlers, `code_change/3`, and local helpers. Only keys used by the \
        module's state gates are tracked. Unchanged fields and process termination have \
        no rows; a `throw` yields `dynamic`.
        """
      },
      %{
        name: :last_send,
        layer: 2,
        fields: [
          {:id, :symbol, "a send: `!`, erlang:send/2,3 or Process.send/3"},
          {:func, :symbol, "the function holding it"}
        ],
        doc: """
        A send that is a tail call or is followed only by returns, with no intervening \
        call, send, or receive. Identifies completion notifications. Functions \
        containing `try` or `catch` are excluded (`Argus.Extractors.OTP`).
        """
      }
    ])
  end
end
