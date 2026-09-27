defmodule Argus.Schema.Callbacks do
  @moduledoc """
  What a callback handles: the message tags it matches, whether it has a
  catch-all, and the continues an `init/1` hands to `handle_continue/2`.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
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
        A message tag a callback matches. Over-approximated: every atom \
        compared anywhere in the body counts, without tracking registers. \
        Consumers ask whether a tag is NOT handled, so over-approximating \
        suppresses findings rather than inventing them.
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
        A clause head of the callback takes the message as the atom `tag` \
        (`arity` 0), or as a tuple of `arity` elements whose first is `tag` \
        (`Argus.Extractors.CallbackTag.MessageClauses.tag_shapes/2`). Read \
        on the heads alone, where callback_tag counts every atom the body \
        compares: `handle_info(:timeout, s)` takes the atom, not \
        `:erlang.start_timer`'s `{:timeout, ref, msg}`, and \
        `handle_info({:tick, n}, s)` takes no `{:tick, 1, :slow}`.
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
        Some clause of the callback takes every `{:DOWN, ref, type, object, \
        reason}` of a monitor of `type`, whatever reason the runtime gives it \
        (`Argus.Extractors.CallbackTag.MessageClauses.takes_down/2`): `any` \
        when the head leaves the type alone, `process` when it compares it \
        with `:process`. A head that pins the ref or the object, or asks the \
        state, takes the `:DOWN` of the monitors the program keeps there; one \
        that tests the reason (`when reason != :normal`) is no row.
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
        Some clause of the callback takes every trapped `{:EXIT, from, \
        reason}`, whatever the reason the linked process ended with \
        (`Argus.Extractors.CallbackTag.MessageClauses.takes_exit?/2`). A head \
        that pins `from` or asks the state takes the exits of the processes \
        the program keeps there; one for `:normal` alone is no row.
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
        The callback's catch-all does nothing with the message but log it or \
        ignore it: every path from its body hands the message, or what is \
        made of it, only to Logger, `:logger`, IO or `inspect/2`. GenServer's \
        own handle_info/2 is one. A catch-all that calls anything else with \
        it, returns it, stores it or tests it is not.
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
        Some clause other than a catch-all takes the message by its shape \
        alone, never comparing it or its tag to a value: `msg when \
        is_atom(msg)` (`any`), `{ref, result} when is_reference(ref)` \
        (`tuple`, a tuple of any tag, of `arity` 2). `callback_tag` names \
        nothing such a clause takes, so a rule asking whether a message is \
        taken asks this too; one asking of a tuple of known size (a \
        monitor's 5-element `:DOWN`) asks the arity as well.
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
        The callback has a catch-all clause, so no tag can fail to match. \
        Established from the bytecode: a multi-clause function raises by \
        jumping to its own `func_info` label, so nothing branching there means \
        every input matches. A guarded catch-all is correctly NOT total.
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
        The call at `id` — into the program, a subscription or a monitor — runs only \
        on some arms of a test of what `func`'s parameter `pos` holds: the \
        parameter, a field of it, or a call's answer on it \
        (`MapSet.member?(state.subscribed, id)`, a stored pid compared with \
        the current one). A test whose other arms only raise (a match that \
        fails with a badmatch, a clause head that fails with a \
        function_clause) decides nothing (Argus.Extractors.LiveView). Where \
        the parameter is a process's state, the call is decided by what \
        the process knows.
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
        The call (or Erlang `!`, the send instruction) at `id` runs only \
        while `func`'s first argument is `tag` — \
        the atom, or the first element of the tuple, some path to the call \
        tested it against — one row per such tag. A call some path reaches \
        without establishing a tag has no row. Exact per path, unlike \
        `callback_tag`: a synchronous call chain follows the clause of \
        handle_call/3 a request enters, and the clause of a guarded \
        dispatcher (`route(:local, n)`) a literal argument enters, so the \
        `:echo` clause that closes a cycle does not stand for the `:answer` \
        clause beside it.
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
        In a handle_info/2, the call at `id` runs on every path the clause \
        for the atom `tag` takes to a return that lets the process go on: \
        every return or tail call the message reaches is reached only \
        through `id` (`Argus.Extractor.Dispatch.reached_with/4`), a return \
        of `{:stop, ...}` left out. A clause that re-arms its own message \
        this way runs a periodic loop; one that re-arms on one branch (after \
        a failed connect) retries until it is done. Computed for atom tags \
        only.
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
        `func` chooses what it runs by its parameter `pos`, and when that \
        parameter holds `:shutdown` — the reason a supervisor stopping a \
        process passes its terminate/2 — some call does not run: it sits in \
        a clause for other reasons (`terminate(:normal, s)`, \
        `terminate_proc(_, r, _) when r != :shutdown`), after a clause that \
        took `:shutdown`, or on a branch of a test the atom does not take. \
        Every path is walked with the parameter fixed \
        (`Argus.Extractor.Dispatch.reached_holding/3`), so a test the walk \
        does not read keeps the calls after it. A function with no row for \
        a parameter runs every call whatever it holds.
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
        For a function that chooses by its parameter `pos` \
        (`shutdown_chooses`), the call at `id` runs when that parameter \
        holds `:shutdown`. One row per call that runs; the calls with no \
        row are the ones the atom never reaches.
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
        The call at `id`, which runs when `func`'s parameter `pos` holds \
        `:shutdown`, hands that value on unchanged as the callee's argument \
        `arg`, on every path that reaches the call with it: \
        `terminate(reason, s)` calling `cleanup(reason, s)` enters \
        `cleanup/2` holding the reason in its first parameter. A call into \
        the runtime (`Argus.Extractor.Runtime`) has no row.
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
        Records that a GenServer module returns `{:ok, _, {:continue, tag}}` from
        `init/1` or `{:noreply, _, {:continue, tag}}` from any handler. The
        deferred-startup-deadlock analysis uses this to identify modules whose
        `handle_continue/2` clauses run during the startup phase.
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
        A `handle_continue(tag, _)` clause defined by a module. The
        deferred-startup-deadlock analysis pairs this with `init_continues_to`
        to find handle_continue bodies reachable from a module's init.
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
        The return at `id` hands the process to `handle_continue/2`: \
        `{:ok, state, {:continue, t}}`, `{:noreply, state, {:continue, t}}` \
        or `{:reply, reply, state, {:continue, t}}`, in init/1, a handler \
        or a helper whose result a callback returns. `tag` is what the \
        clause of handle_continue/2 the term enters tells it by: the atom, \
        or a tuple's first element. One row per clause of `func` the return \
        is in, by the tag its first argument was established to be \
        (`Argus.Extractor.Dispatch.argument_tags/2`, as `returned_update` \
        reads one). What sends a clause of handle_continue/2 its term, for \
        `clientlib/runs.dl`'s once clauses.
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
        The return at `id` arms its loop's idle timeout: `{:ok, state, ms}`, \
        `{:noreply, state, ms}` or `{:reply, reply, state, ms}`, whose \
        `:timeout` message comes when no other does first. A value the \
        return does not spell counts: only `:infinity`, `:hibernate` and a \
        continue are known not to be a timeout. Read in every function, as \
        `continue_return` is, one row per clause the return is in. Unlike \
        `callback_timeout` (a callback's literal integer), what makes a \
        `:timeout` message, for `clientlib/runs.dl`'s once clauses.
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
        The call or receive at `id` runs only after `func` has \
        acknowledged its start: every path from the function's entry to \
        it passes a `:proc_lib.init_ack/1,2` (`Argus.Extractors.OTP`). A \
        process started with `:proc_lib.start_link/3` holds its starter \
        until that ack; an init/1 that acks and then enters its own loop \
        (`:gen_server.enter_loop/3`, OTP's logger_olp) waits there as the \
        server, not as the start. An ack made in a helper the function \
        calls is not seen.
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
        The call (or send) at `site`, in a GenServer handler \
        (handle_call/3, handle_cast/2, handle_info/2, handle_continue/2), \
        runs only while the state the handler was handed holds `value` \
        under `key`: on every path from the entry to the site, the tests \
        of that field admit only the atoms of the site's rows (a clause \
        head `%{registered: false}`, `if state.timer == nil`, `case \
        state.status`; `if state.owner` admits nil and false). A field of \
        a value made from the state (a nested map, `Map.get/2`) is not \
        read, nor a struct's `__struct__`. \
        (`Argus.Extractors.StateGate`.)
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
        Every way `func` completes after `site` hands back a state whose \
        `key` holds a value none of the site's state_gate rows admits — a \
        literal outside them, a value no atom is (what a call known to \
        answer a reference, a pid or a number made, the caller in \
        handle_call/3's `from`), no such field — or ends the process (a \
        `{:stop, ...}`, a raise). A return through a local helper handed \
        the state reads the helper's returns; the handler of a `try` the \
        site may be inside is a way to complete. A `throw` after the site \
        (gen_server takes the thrown value as the result), a state handed \
        back unchanged, or one the reading cannot follow, closes nothing.
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
        The call (or send) at `site`, in a GenServer handler, does not run \
        while the state the handler was handed holds `value` under `key`: \
        the walk from the entry with the field fixed at that atom misses \
        it, and another walk reaches it. `handle_info(ev, %{status: \
        :init} = s)` queues what the next clause serves: the serving call \
        is excluded while the status is `:init`. \
        (`Argus.Extractors.StateGate`.)
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
        A way `func` completes, in its clause for `clause`, hands back a \
        state whose `key` holds `value`: the handlers' returns \
        (`{:noreply, state, ...}`, `{:reply, reply, state, ...}`), \
        code_change/3's `{:ok, state}`, and init/1's `{:ok, state, ...}`, \
        the state each incarnation starts with; through the local helpers \
        they return through or hand the state to. A return that keeps the \
        field, or ends the process, has no row; a `throw` in the function \
        is `dynamic`. Read only for the keys the module's gates test: what \
        could set a gate's field back, and what a field starts as.
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
        The send at `id` is `func`'s last act: it is a tail call, or every \
        path on from it returns with no call, send or receive between \
        (`Argus.Extractors.OTP`). Everything else the function does it \
        has done when the message goes: a loader spawned to fill its \
        starter's tables that ends by reporting it is done. A function \
        with a `try` or a `catch` has no rows.
        """
      }
    ])
  end
end
