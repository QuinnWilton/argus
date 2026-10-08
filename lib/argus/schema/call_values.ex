defmodule Argus.Schema.CallValues do
  @moduledoc """
  Layer-2 facts for call arguments, result usage, shared-state keys and names, and \
  return specifications. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :call_arg,
        layer: 2,
        # Keyed by caller rather than instruction ID: consumers need argument values per
        # function, and body edits can renumber call sites.
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position"},
          {:value, :symbol,
           "resolved value: a literal atom, binary or integer as key identities spell it, or 'dynamic'"}
        ],
        doc: """
        A resolved call argument. `resolved_arg` in `clientlib/calls.dl` propagates \
        literals through wrappers to resolve call and cast targets. Forwarded parameters \
        use `call_arg_forward` instead.
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
        A call argument derived from a caller parameter, including destructuring, \
        construction, and known data-preserving calls. Includes `call_arg_forward`. For \
        `make_fun3`, captured variables are trailing arguments. Function-level, so \
        unchanged flows survive body edits.
        """
      },
      %{
        name: :call_arg_param,
        layer: 2,
        fields: [
          {:id, :symbol, "call instruction ID"},
          {:func, :symbol, "calling function ID"},
          {:arg_pos, :number, "zero-based call argument position"},
          {:param_pos, :number, "caller parameter from which this argument is derived"}
        ],
        doc: """
        Parameter provenance at one concrete call site, with the same data-flow \
        semantics as call_arg_derived. Distinguishes multiple calls to the same \
        callee, so safety at one cannot be applied to another. Includes every \
        argument position of direct local and remote calls.
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
        A call argument read from a literal map key in the caller, such as `state.ref`. \
        Emitted only when `call_arg` reports `dynamic`.
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
        A call argument taken from element `index` of a caller parameter. Covers tuple \
        extraction instructions and `element/2`. Emitted only when `call_arg` reports \
        `dynamic`.
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
        Element `index` of a tuple argument constructed by the caller, expressed as \
        `(source, value)` in `key_identity` vocabulary. Identifies record tables and \
        keys or ETS object keys. Unresolved elements are omitted.
        """
      },
      %{
        name: :mfa_arg,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID of the call"},
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "called function ID"},
          {:pos, :number, "0-based position of the module argument"},
          {:mod, :symbol, "the module, inspected as function_def spells it"},
          {:target, :symbol, "the function the three name, `Mod:fun/arity`"}
        ],
        doc: """
        A literal module and function plus a list of known length, passed at consecutive \
        positions starting at `pos`. Identifies an MFA in `function_def` format for \
        RPC-wrapper resolution, anchored to the call site.
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
        A literal `:infinity` argument at any position. Complements `call_arg`, which \
        records only the first four positions and can miss timeout arguments.
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
        A caller parameter passed unchanged to a callee argument. Used for \
        interprocedural constant propagation. Positions are numeric columns to avoid \
        partial string functors, which a solver may evaluate before their guards.
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
        A process or OTP API call's result usage, failure class, and literal target when \
        known. One row per site supports comparison with other calls to the same callee \
        and target. `try_covers` and `catch_class` determine whether the failure is \
        handled.
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
        A call that registers a name or starts a process, including via registration and \
        `start_child` with a name in its child spec.
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
        The identity of an ETS key operand; for `insert` and `insert_new`, the object's \
        first element. Matching `source` and `key` values identify the same row.
        """
      },
      %{
        name: :ets_key_element,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the ETS operation"},
          {:pos, :number, "0-based element position"},
          {:source, :symbol, "literal | param | field | local | element N | self | tuple"},
          {:value, :symbol, "as ets_key spells its key"}
        ],
        doc: """
        An element of a tuple key `ets_key` names `tuple`, in `ets_key` vocabulary \
        (`Identity.key_elements/4`). Every element has a row: a key of n elements has \
        rows at positions 0 to n - 1. Not emitted for match patterns.
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
        An ETS table operand's root and map access path (`Resolve.access_path/4`). \
        Distinguishes tables stored under different keys of one map. Conflicting writers \
        have no row; a fallback expression such as `cfg.table || @default` has a path \
        for each arm.
        """
      },
      %{
        name: :ets_table_default,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the ETS operation"},
          {:name, :symbol, "the inspected literal name"},
          {:site, :instr_id, "the call whose answer was tested"}
        ],
        doc: """
        An ETS table operand that defaults to literal `name` when the call at `site` \
        returns `undefined`, `nil`, or `false`; otherwise it uses that call's result. \
        The literal also appears in `ets_table_path`.
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
        A call or closure capture receiving a table reference returned by `:ets.new/2` \
        in the caller. Unnamed tables use their creation name so parameter-based \
        operations can join `ets_new`. Function-level, like `call_arg`.
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
        An identifiable non-key element written by ETS `insert` or `insert_new`, using \
        `ets_key` vocabulary. Supports joins where one table stores another table's key. \
        Unresolved elements are omitted.
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
        Two ordered effects within one function iteration. At least one is an insert or \
        a same-module call that inserts. Excludes loop back edges so writes in a loop \
        are ordered within an iteration, not in both directions.
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
        A call argument's identity in `ets_key` vocabulary. Translates a callee's \
        parameter-based insert key into the caller's terms.
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
        A Mnesia dirty operation's table and key, outside transaction serialization. \
        Single-argument forms derive both from `{table, key}` or the first two record \
        elements.
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
        Two Mnesia writes ordered within one function iteration, excluding loop back \
        edges (`Argus.Extractors.Mnesia`). Writes ordered in neither direction lie on \
        mutually exclusive paths.
        """
      },
      %{
        name: :mnesia_written_when_found,
        layer: 2,
        fields: [
          {:read, :instr_id, "a Mnesia read (mnesia_op kind read)"},
          {:write, :instr_id, "a Mnesia write (mnesia_op kind write) of the same function"}
        ],
        doc: """
        No path from the side of a test of the read's answer that found no record \
        reaches the write: the write follows the read only where it found the record \
        (`Argus.Extractor.AnswerSides`). A read whose answer is not tested first has \
        no rows.
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
        A process-name lookup, its name identity, and whether the result is checked for \
        `nil` or `[]` before use. Joins creating operations on the same name. \
        `Process.registered/0` and `:erlang.registered/0` use source `any`.
        """
      },
      %{
        name: :nil_use,
        layer: 2,
        fields: [
          {:id, :instr_id, "an unchecked whereis (name_lookup)"},
          {:func, :func_id, "function containing it"},
          {:use, :instr_id,
           "the call that first uses the result, or the lookup itself when that use is no call"},
          {:fails, :symbol,
           "error | exit | none | any: how that use fails when the result is nil"}
        ],
        doc: """
        The failure class of the first use of an unchecked `whereis` result: `error` for \
        sends or BIFs, `exit` for calls, `none` for casts, and `any` when unknown. A \
        handler must catch this class to cover an unregistered name.
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
        Normalized return claims from `@spec` (`Argus.Specs`): `can_fail`, `total`, \
        `constant`, `no_return`, or `returns_pid`. Failure values include `{:error, _}`, \
        `:error`, `nil`, `false`, `:undefined`, and `{:EXIT, _}`. A function may have \
        several shapes; no row means unknown. Specs come from analyzed BEAMs or the code \
        path, with `clientlib/specs.dl` preferring analyzed definitions. Rules use these \
        unverified claims only to confirm or suppress findings.
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
        A function generated by a macro, a `generated: true` marker, or an OTP header. \
        Elixir uses definition metadata; Erlang uses abstract-code file attributes, \
        falling back to `yecc*` names for parsers without abstract code. The origin \
        identifies library-generated call sites.
        """
      },
      %{
        name: :macro_written,
        layer: 2,
        fields: [{:func, :func_id, "function ID (mod:func/arity)"}],
        doc: """
        A function whose every clause is generated by a macro, generation marker, OTP \
        header, or yecc (`Argus.Extractors.Generated`). Unlike `macro_generated`, checks \
        all clauses rather than the first clause's metadata.
        """
      },
      %{
        name: :tooling_module,
        layer: 2,
        fields: [
          {:mod, :symbol, "the module, inspected"},
          {:basis, :symbol,
           "mix (an Elixir module under Mix.) | test_support (compiled from test/support/ " <>
             "or from a test/ directory within a lib/)"}
        ],
        doc: """
        A module identified as developer tooling or test support by its name or compile \
        path (`Argus.Extractors.Tooling`). `clientlib/tooling.dl` lowers finding \
        severity there; the tooling prior classifies unresolved modules.
        """
      },
      %{
        name: :doc_hidden,
        layer: 2,
        fields: [{:func, :func_id, "function ID (mod:func/arity)"}],
        doc: """
        An exported function the Docs chunk hides from the module's users: `@doc false`, \
        `@impl true` without a `@doc`, or any function of a `@moduledoc false` module \
        (`Argus.Extractors.Docs`). `unsafe_input.dl` does not count it as a way in for a \
        caller's data. A beam without a Docs chunk hides nothing.
        """
      },
      %{
        name: :quoted_call,
        layer: 2,
        fields: [
          {:func, :func_id, "the function whose quote names the call"},
          {:mod, :symbol, "the called module, inspected"},
          {:name, :symbol, "the called function's name"},
          {:arity, :number, "the call's arity, or -1 when its arguments are not known"},
          {:context, :symbol,
           "function (inside a function or nested quote the quote defines) | expansion (at the " <>
             "top of the code a macro returns)"}
        ],
        doc: """
        A remote call in a quote's literal or a macro's rebuilt return value \
        (`Argus.Extractors.Quoted`). It runs where the quote expands, not where the beams \
        call: `unsafe_input.dl` keeps a hidden helper a generated function calls as a way \
        in, and does not count a `__name__` hook only expansions call as one.
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
        A `Process.unregister/1` or `:erlang.unregister/1` call. Raises if the name is \
        already unregistered, including when a preceding lookup becomes stale.
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
        Parameter-derived data at an atom-creation, deserialization, or code-execution \
        sink, keyed by site. Chains with `call_arg_derived` to establish data flow from \
        request parameters.
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
           "empty when the bound holds; 'atoms' for an atom made of atoms that exist, " <>
             "which holds where those atoms are not the caller's choice; else the position " <>
             "of the function's list parameter the bound needs to be a literal list"}
        ],
        doc: """
        A sink argument restricted on every path to at most 1,024 values, through \
        literal tests, allowlists, bounded integers, or combinations of bounded values \
        (`Argus.Extractors.ParamFlow.Bounded`). Combined bounds multiply. A list \
        parameter is a bound only when callers pass literal lists \
        (`call_arg_allowlist`). At atom sinks, `list_param` value `atoms` means \
        existing-atom input; this is bounded only if outsiders cannot choose the atoms \
        and newly created atoms cannot feed back.
        """
      },
      %{
        name: :sink_arg_chosen,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the sink call"},
          {:func, :func_id, "function containing the sink"},
          {:arg_pos, :number, "0-based argument position at the sink"}
        ],
        doc: """
        A sink argument derived from an existing-atom lookup in the same function. \
        Caller-selected existing atoms can produce new atoms that later lookups select, \
        so this does not establish a bound on atom creation.
        """
      },
      %{
        name: :call_arg_chosen,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position at the call site"}
        ],
        doc: """
        A call argument derived from an existing-atom lookup in the caller. Chains with \
        `call_arg_derived` to detect caller-selected atoms reaching a sink.
        """
      },
      %{
        name: :sink_arg_config,
        layer: 2,
        fields: [
          {:id, :instr_id, "instruction ID of the sink call"},
          {:func, :func_id, "function containing the sink"},
          {:arg_pos, :number, "0-based argument position at the sink"}
        ],
        doc: """
        A sink argument derived from a read of the application environment in the \
        same function (`Application.get_env/2,3` and kin): the host's configuration. \
        It may hold other data as well; this names one origin, not the only one.
        """
      },
      %{
        name: :call_arg_config,
        layer: 2,
        fields: [
          {:caller, :symbol, "calling function ID"},
          {:callee, :symbol, "callee function ID (mod:func/arity)"},
          {:arg_pos, :number, "0-based argument position at the call site"}
        ],
        doc: """
        A call argument derived from a read of the application environment in the \
        caller. Chains with `call_arg_derived` to find configuration reaching a sink.
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
        A sink call with an earlier call to the same API on the same source line in the \
        same function. Identifies compiler duplication of a body shared by clause heads.
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
        Every call from caller to callee passes a literal list at this position. \
        Compiled module attributes count as literals. Any nonliteral argument at that \
        position removes the function-level row.
        """
      }
    ])
  end
end
