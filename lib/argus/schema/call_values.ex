defmodule Argus.Schema.CallValues do
  @moduledoc """
  What flows into and out of a call: the arguments a site passes
  (literal, forwarded, read from a field, derived from a parameter),
  what becomes of a result, the keys and names shared-state operations
  use, and what specs claim a callee returns.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Cache.Reads.record("relations #{__MODULE__}", [
      %{
        name: :call_arg,
        layer: 2,
        # Deliberately NOT keyed by call-site instruction ID. That column
        # renumbered whenever anything earlier in the function changed, so
        # call_arg churned on every body edit — while no rule ever bound it
        # (every use wildcarded position 1). The rules ask which FUNCTION
        # passes which argument, which is stable.
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position"},
          {:value, :symbol,
           "resolved value: a literal atom, binary or integer as key identities spell it, or 'dynamic'"}
        ],
        doc: """
        Resolved argument value at a call site. Enables interprocedural \
        constant propagation: `resolved_arg` in `clientlib/calls.dl` traces \
        literal values from call sites through forwarding chains to resolve \
        `sync_call`/`async_cast` targets the extractors couldn't resolve \
        statically. Forwarded parameters are NOT values here \
        — they are their own relation, `call_arg_forward`.
        """
      },
      %{
        name: :call_arg_derived,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position at the call site"},
          {:param_pos, :number,
           "0-based position of the caller's parameter the argument is derived from"}
        ],
        doc: """
        At some call site in the caller, the argument is data-dependent on \
        one of the caller's parameters: destructured out of it, built into a \
        tuple or a binary with it, or returned by a call known to hand its \
        argument's data through. A superset of call_arg_forward (identity is a \
        dependence). A closure built with make_fun3 counts as a call whose \
        trailing parameters are the captured environment. Function-level, so \
        a body edit that keeps the flow does not move it.
        """
      },
      %{
        name: :call_arg_field,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "called function ID"},
          {:arg_pos, :number, "argument position (0-based)"},
          {:key, :symbol, "the inspected map key the argument was read from"}
        ],
        doc: """
        The argument at `arg_pos` was read from a map under a literal key in \
        the caller (`start_timer(ms, state.ref)`): which piece of the \
        caller's state a helper is handed. Only emitted where call_arg says \
        'dynamic'.
        """
      },
      %{
        name: :call_arg_element,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "called function ID"},
          {:arg_pos, :number, "argument position (0-based)"},
          {:param_pos, :number, "the caller's parameter the element is taken from (0-based)"},
          {:index, :number, "the element's position in that tuple (0-based)"}
        ],
        doc: """
        The argument at `arg_pos` is element `index` of the caller's own \
        parameter (`elem(record, 1)`, a `get_tuple_element` or the \
        `element/2` BIF): what a helper that names the value by its own \
        parameter is handed, in the caller's terms. Only emitted where \
        call_arg says 'dynamic'.
        """
      },
      %{
        name: :call_arg_tuple,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "called function ID"},
          {:arg_pos, :number, "argument position (0-based)"},
          {:index, :number, "the element's position in the tuple (0 or 1)"},
          {:source, :symbol, "literal | param | field | element N"},
          {:value, :symbol, "the element, in the vocabulary of key_identity"}
        ],
        doc: """
        The argument at `arg_pos` is a tuple the caller builds, and its \
        element `index` is `(source, value)` in the caller's terms: a \
        record's table (element 0) and key (element 1), an ETS object's \
        key. A callee that names the element by its parameter is handed \
        this. Elements the caller cannot name are not emitted.
        """
      },
      %{
        name: :infinity_arg,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position"}
        ],
        doc: """
        A call passes the literal `:infinity` as an argument, at any \
        position — call_arg stops at the fourth, and a timeout is often \
        the fifth. A wrapper whose timeout defaults to :infinity compiles \
        to a clause that calls the full arity with it.
        """
      },
      %{
        name: :call_arg_forward,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position at the call site"},
          {:fwd_pos, :number, "0-based position of the caller's own parameter being forwarded"}
        ],
        doc: """
        A call site passes one of the caller's own parameters straight through \
        as an argument — the forwarding step interprocedural constant \
        propagation walks backwards.

        Split out of `call_arg`, where it used to be encoded in the value \
        column as the string `"arg:N"` and decoded in Datalog with \
        `to_number(substr(...))`. `to_number` is a PARTIAL functor: it aborts \
        on input that is not numeric. The guard that kept non-forwarding values \
        away from it was a sibling conjunct, and Souffle does not promise \
        conjunct order — the default schedule happened to be safe, but the \
        magic-set transform reordered and aborted with `to_number("mic")`. A \
        structured column cannot be scheduled into a crash.
        """
      },
      %{
        name: :call_result,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing the call"},
          {:callee, :func_id, "callee function ID (mod:func/arity)"},
          {:fate, :symbol, "used | ignored | returned | dynamic"},
          {:raises, :symbol,
           "the class a failing call raises: exit (a call into a process) | " <>
             "error (a BIF, an ETS operation) | * (either)"},
          {:target, :symbol, "the first argument, inspected, when it is a literal; else empty"}
        ],
        doc: """
        A call to a process or OTP API, or to anything that starts a process, \
        with what became of its result, the class it raises when it fails \
        (what a try must take to guard it: try_covers and catch_class), and \
        what it acts on when a literal says. One row per site, so a \
        rule can count how the other sites of the same callee (on the same \
        target) behave and report the one that disagrees.
        """
      },
      %{
        name: :creating_op,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing the call"},
          {:api, :symbol,
           "register | start_link | start | start_via | registry_register | start_child"},
          {:scope, :symbol, "the Registry, for start_via and registry_register; empty otherwise"},
          {:source, :symbol, "literal | param | field | local | dynamic"},
          {:key, :symbol, "the name claimed; empty when the source is dynamic"}
        ],
        doc: """
        A call that claims a name or starts a process: a registration, a \
        named start, a via-registered start, or start_child, whose name hides \
        in the child spec.
        """
      },
      %{
        name: :ets_key,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the ETS operation"},
          {:source, :symbol, "literal | param | field | local | dynamic"},
          {:key, :symbol,
           "the key: an inspected literal, a parameter index, a map key, or the instruction that made it"}
        ],
        doc: """
        What identifies the key operand of an ETS operation; for insert and \
        insert_new, the first element of the object. Two operations agreeing \
        on source and key touch the same row.
        """
      },
      %{
        name: :ets_table_path,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the ETS operation"},
          {:source, :symbol, "literal | param | local"},
          {:root, :symbol,
           "the inspected name, the parameter's 0-based position, or the instruction that made the value"},
          {:path, :symbol,
           "the map keys read from the root, joined by \".\"; empty for the root itself"}
        ],
        doc: """
        Where the table operand of an ETS operation was read from: a root and \
        the map keys read from it (Resolve.access_path/4). Two tables handed \
        to a function in one map, `%{forward: f, reverse: r}`, are two paths \
        under one root where ets_op knows both by the name they were created \
        with. Absent when the operand's writers disagree; a table named by a \
        join (`cfg.table || @default`) is to have one row per arm.
        """
      },
      %{
        name: :ets_tid_arg,
        layer: 2,
        fields: [
          {:caller, :func_id, "the function that created the table"},
          {:callee, :func_id, "the function or closure it hands the table to"},
          {:arg_pos, :number,
           "0-based argument position, or the closure's environment parameter"},
          {:name, :symbol, "the name :ets.new/2 was given, inspected"}
        ],
        doc: """
        At some call in the caller, or in the environment of a closure it \
        builds, the argument is the table reference :ets.new/2 returned in the \
        caller. An unnamed table is known by the name it was created with, so \
        an operation on the parameter joins ets_new like a named one. \
        Function-level, like call_arg.
        """
      },
      %{
        name: :ets_value,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the insert or insert_new"},
          {:pos, :number, "0-based element position, 1 and up (element 0 is ets_key)"},
          {:source, :symbol, "literal | param | field | local"},
          {:value, :symbol, "as ets_key spells its key"}
        ],
        doc: """
        What identifies an element past the key of the object an insert or \
        insert_new writes, in ets_key's vocabulary: a row holding a value \
        another table is keyed by joins that table's key on it. An element \
        nothing identifies has no row.
        """
      },
      %{
        name: :ets_effect_order,
        layer: 2,
        fields: [
          {:func, :func_id, "the function both effects are in"},
          {:first, :instr_id, "an insert/insert_new, or a call into project code"},
          {:then, :instr_id, "an effect control reaches from it without closing a loop"}
        ],
        doc: """
        Two effects of one function in order within one trip through it: \
        inserts, and the calls a callee's inserts hide behind. An edge into a \
        block that dominates its source is a loop's back edge and is not \
        followed, so a loop body's writes are ordered as each iteration makes \
        them, not both ways. At least one of the two is an insert or a call \
        to a function of the same module that inserts.
        """
      },
      %{
        name: :ets_call_arg,
        layer: 2,
        fields: [
          {:id, :instr_id, "a call ets_effect_order orders"},
          {:callee, :func_id, "the function called"},
          {:pos, :symbol, "0-based argument position, as a symbol"},
          {:source, :symbol, "literal | param | field | local"},
          {:value, :symbol, "as ets_key spells its key"}
        ],
        doc: """
        What identifies an argument of the call, in ets_key's vocabulary: a \
        callee's insert keyed by its parameter is keyed, in the caller, by \
        what the caller passes there.
        """
      },
      %{
        name: :mnesia_op,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing the call"},
          {:op, :symbol, "dirty_read | dirty_write | dirty_delete | dirty_delete_object"},
          {:kind, :symbol, "read | write"},
          {:table_source, :symbol, "literal | param | field | local | dynamic"},
          {:table, :symbol,
           "the table: an inspected literal, a parameter index, a map key, or the instruction that made it"},
          {:key_source, :symbol, "literal | param | field | local | dynamic"},
          {:key, :symbol,
           "the key: an inspected literal, a parameter index, a map key, or the instruction that made it"}
        ],
        doc: """
        A Mnesia dirty operation, outside any transaction's serialization, \
        with the table and key it touches. The one-argument forms carry both \
        in a tuple: {table, key}, or a record whose first element is its \
        table and whose second is its key.
        """
      },
      %{
        name: :mnesia_write_order,
        layer: 2,
        fields: [
          {:func, :func_id, "the function holding both writes"},
          {:first, :instr_id, "a Mnesia write (mnesia_op kind write)"},
          {:then, :instr_id, "a Mnesia write that can run after it"}
        ],
        doc: """
        Two Mnesia writes of one function, `then` reachable from `first` \
        within one trip through it (`Argus.Extractors.Mnesia`; a loop's \
        back edge is not followed). Two writes ordered neither way are on \
        paths that exclude each other: an upsert's two branches.
        """
      },
      %{
        name: :name_lookup,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the lookup"},
          {:func, :func_id, "function containing the lookup"},
          {:api, :symbol, "whereis | registry_lookup | registered"},
          {:scope, :symbol, "the Registry, for registry_lookup; empty otherwise"},
          {:source, :symbol, "literal | param | field | local | dynamic, or any for registered"},
          {:key, :symbol,
           "the name: an inspected literal, a parameter index, a map key, or the instruction that made it"},
          {:checked, :symbol, "checked | unchecked: is the result tested against nil before use"}
        ],
        doc: """
        A process name looked up — Process.whereis/1, :erlang.whereis/1, \
        Registry.lookup/2 — with what identifies the name, so a creating op \
        on the same name can be joined to it, and whether the result is \
        tested against nil (or []) before use. Process.registered/0 and \
        :erlang.registered/0 look up every name at once: source any.
        """
      },
      %{
        name: :spec_return,
        layer: 2,
        fields: [
          {:func, :func_id, "function ID (mod:func/arity)"},
          {:shape, :symbol, "can_fail | total | constant | no_return | returns_pid"},
          {:origin, :symbol,
           "analyzed | installed: read from the analyzed beam, or from the code path"}
        ],
        doc: """
        What a function's `@spec` claims it returns, normalized (`Argus.Specs`): \
        `can_fail` when the return type names {:error, _}, :error, nil, false, \
        :undefined or {:EXIT, _}; `total` when it is known and names none of \
        them; `constant` when it is one literal atom (and so also total); \
        `no_return`; `returns_pid`. A function may have several shapes, \
        and one with no row is unknown — no spec, a `term()` return, a module \
        shipped without specs (:mnesia) — never "cannot fail". Rows come from \
        the analyzed module's own beam for its functions, and from the code \
        path for the remote functions it calls; clientlib/specs.dl prefers the \
        first. A spec is an unverified claim: rules use these rows only to \
        suppress or confirm a finding, never to report one on their own.
        """
      },
      %{
        name: :macro_generated,
        layer: 2,
        fields: [
          {:func, :func_id, "function ID (mod:func/arity)"},
          {:by, :symbol,
           "the module whose macro defined it, inspected; generated; an OTP header's " <>
             "file name; or yecc"}
        ],
        doc: """
        A function another module's macro wrote into this one — `use Ecto.Repo` \
        defines `stop/1` in the repo — read from the `context:` Elixir records \
        in each definition's debug-info metadata, or its `generated: true` \
        marker (`generated`). In an Erlang module, a function the abstract \
        code places under a `-file` attribute naming an OTP header \
        (`yeccpre.hrl`, `leexinc.hrl`, an installed application's include), \
        by that header's name; without abstract code, a yecc parser's \
        `yecc*` functions (`yecc`). Its call sites are the library's, not \
        the program's.
        """
      },
      %{
        name: :macro_written,
        layer: 2,
        fields: [{:func, :func_id, "function ID (mod:func/arity)"}],
        doc: """
        Every clause of `func` was written by another module's macro, or \
        marked `generated: true`, or an OTP header or yecc defined it \
        (`Argus.Extractors.Generated`): the module wrote none of it. `macro_generated` reads the definition's \
        metadata, which is its first clause's, and so names a function \
        whose first clause a `use` injected ahead of the module's own; \
        this reads each clause's. `use Cachex.Warmer`'s handle_info/2 is \
        one.
        """
      },
      %{
        name: :name_release,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the call"},
          {:func, :func_id, "function containing the call"},
          {:api, :symbol, "unregister"},
          {:source, :symbol, "literal | param | field | local | dynamic"},
          {:key, :symbol,
           "the name: an inspected literal, a parameter index, a map key, or the instruction that made it"}
        ],
        doc: """
        A registered name given up — Process.unregister/1, \
        :erlang.unregister/1 — which raises when the name is no longer \
        registered: a lookup that decides it is stale once the process exits \
        or another process unregisters first.
        """
      },
      %{
        name: :sink_arg_derived,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the sink call"},
          {:func, :func_id, "function containing the sink"},
          {:arg_pos, :number, "0-based argument position at the sink"},
          {:param_pos, :number,
           "0-based position of the function's parameter the argument is derived from"}
        ],
        doc: """
        call_arg_derived at a sink site — atom creation, deserialization, code \
        execution — keyed on the site because the finding anchors there. \
        Together with call_arg_derived it lets a rule chain a request entry's \
        parameter to the sink's argument: a proven flow rather than a call path.
        """
      },
      %{
        name: :sink_arg_bounded,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the sink call"},
          {:func, :func_id, "function containing the sink"},
          {:arg_pos, :number, "0-based argument position at the sink"},
          {:list_param, :symbol,
           "empty when the bound holds; else the position of the function's list " <>
             "parameter the bound needs to be a literal list"}
        ],
        doc: """
        On every path to the sink, its argument is one of a set the program \
        wrote: compared equal to a literal (a clause head, a guard's `in`, a \
        case arm), or found in a literal list (`x in @allowed`, \
        `:lists.member/2`, `Enum.member?/2`) on the branch where it holds \
        (Argus.Extractors.ParamFlow.Bounded). A membership test against a list \
        the function takes as a parameter bounds it only where the callers \
        pass a literal list (call_arg_allowlist): `list_param` names that \
        parameter.
        """
      },
      %{
        name: :sink_copy,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the sink call"},
          {:func, :func_id, "function containing it"},
          {:first, :instr_id, "the earliest sink call of the same API on the same source line"}
        ],
        doc: """
        A sink call the compiler duplicated: another call of the same API \
        in the same function sits on the same source line, earlier. A body \
        two clause heads share is compiled once per head.
        """
      },
      %{
        name: :call_arg_allowlist,
        layer: 2,
        fields: [
          {:caller, :func_id, "the calling function"},
          {:callee, :func_id, "the callee"},
          {:arg_pos, :number, "0-based argument position"}
        ],
        doc: """
        Every call the caller makes to the callee passes a literal list at \
        the position (a module attribute is one once compiled). \
        Function-level: one call passing anything else, and there is no row.
        """
      }
    ])
  end
end
