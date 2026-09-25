defmodule Argus.Schema.Callbacks do
  @moduledoc """
  What a callback handles: the message tags it matches, whether it has a
  catch-all, and the continues an `init/1` hands to `handle_continue/2`.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
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
          {:shape, :symbol, "'any' | 'tuple'"}
        ],
        doc: """
        Some clause other than a catch-all takes the message by its shape \
        alone, never comparing it or its tag to a value: `msg when \
        is_atom(msg)` (`any`), `{ref, result} when is_reference(ref)` \
        (`tuple`, a tuple of any tag). `callback_tag` names nothing such a \
        clause takes, so a rule asking whether a message is taken asks \
        this too.
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
        name: :clause_call,
        layer: 2,
        fields: [
          {:id, :symbol, "a call"},
          {:func, :symbol, "the function holding it"},
          {:tag, :symbol, "the inspected tag its first argument is established to be"}
        ],
        doc: """
        The call at `id` runs only while `func`'s first argument is `tag` — \
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
        name: :skipped_on_shutdown,
        layer: 2,
        fields: [
          {:id, :symbol, "a call"},
          {:func, :symbol, "the terminate/2 or terminate/3 holding it"}
        ],
        doc: """
        The call at `id` does not run when `func`, a `terminate/2` or \
        `terminate/3` that chooses its clause by the reason, is called with \
        `:shutdown` — the reason a supervisor stopping the process passes. \
        It sits in a clause for other reasons (`terminate(:normal, s)`), or \
        after one that took `:shutdown`. Every path is walked with the \
        reason fixed (`Argus.Extractor.Dispatch.reached_with/3`), so a test \
        this does not read keeps the call.
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
      }
    ])
  end
end
