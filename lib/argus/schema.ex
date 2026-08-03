defmodule Argus.Schema do
  @moduledoc """
  Fact relation definitions for Argus analysis.

  Each relation describes a table of facts that Argus extracts from BEAM
  bytecode or domain extractors. Relations map directly to Souffle `.decl`
  declarations and `.facts` files.

  ## Layers

  - **Layer 1** — generic bytecode facts extracted from any BEAM module.
  - **Layer 2** — domain-specific facts from pluggable extractors.
  """

  @typedoc """
  The semantic kind of a relation field.

  `:symbol` and `:number` are the raw Souffle types. The richer kinds drive
  `Argus.Facts.decode/1` for in-process consumers while serializing to the
  same Souffle types (`:instr_id`/`:func_id` → `symbol`, `:label` → `number`):

  - `:instr_id` — an instruction ID (`"Mod:func/arity#idx"`), decoded to
    `Argus.InstrId.t()`.
  - `:func_id` — a function ID (`"Mod:func/arity"`), kept as a string.
  - `:label` — a BEAM label number (0 conventionally means "no label").
  """
  @type field_type :: :symbol | :number | :instr_id | :func_id | :label
  @type field :: {atom(), field_type(), String.t()}

  @type relation :: %{
          name: atom(),
          layer: 1 | 2,
          fields: [field()],
          doc: String.t()
        }

  # Bump whenever a relation is added/removed, any field changes name,
  # position, or kind, or a field's *meaning* changes — in-process consumers
  # (e.g. lowdown) assert against this at compile time. Independent of the
  # package version; record bumps in CHANGELOG.md.
  #
  # Version 2: line_info.line became a real source line (the emitter now
  # resolves the Line chunk's references); under version 1 it carried the
  # raw chunk reference despite the field's documentation.
  #
  # Version 3: line_info covers every instruction (the line in effect,
  # sticky from the last resolvable marker) rather than only the markers
  # themselves, so call-site instruction IDs resolve to exact lines; and
  # supervisor gained a trailing site column (the instruction that defines
  # the tree) so supervision findings can anchor at the strategy line.
  #
  # Version 4: added the supervisor_child_name relation — a child spec's
  # registered :name, paired with the child by {sup, position} — so a
  # dynamic_child parented by a registered name can be anchored to the
  # child that registers it.
  #
  # Version 5: global_register gained a trailing arity column so the
  # distributed analysis can distinguish :global.register_name/2 (default
  # conflict resolution, race-prone on partition) from /3 (explicit
  # resolver — the fixed form, which must not be flagged).
  #
  # Version 6: added the statem_initial relation — the gen_statem initial
  # state read from init/1's return — so the reachability analysis stops
  # guessing the entry point topologically.
  #
  # Version 7: added the port_open relation — external port creation sites
  # (Port.open, System.cmd, ...), owned by the opening process, so consumers
  # can attribute ports to their process in the supervision tree.
  # Version 8: split positional columns out of the fact schema so relations
  # stop churning on edits that cannot affect them. `function_def` lost its
  # `entry` label to the new `function_entry` relation, and `call_arg` lost
  # its call-site instruction ID. Neither column was ever bound by a rule
  # (entry wildcarded in all 55 uses, call_arg's id in all of them), yet
  # both renumber whenever anything earlier in a function changes — which
  # dirtied every analysis reading those relations on any body edit. Same
  # principle that keeps line_info out of a semantic fact set: positional
  # data is payload to resolve late, never a join key.
  # Version 9: `call_arg` no longer encodes parameter forwarding as the
  # string `"arg:N"` in its value column. Forwardings are their own
  # relation, `call_arg_forward`, with the forwarded position as a real
  # `number` field. The string encoding forced `clientlib/interprocedural.dl`
  # to decode it with `to_number(substr(...))`, and `to_number` is a PARTIAL
  # functor — it aborts on non-numeric input. The `match("arg:.*", ...)`
  # guard was a sibling conjunct rather than a precondition, and Souffle
  # promises no conjunct order: the default schedule was safe, the
  # magic-set transform was not. Structure that matters to a rule belongs
  # in a column, not in a string a functor has to parse back out.
  # Version 10: the call-shaped relations carry their containing function.
  # `remote_call`, `local_call`, `bif_call`, `spawn_call` and `try_start`
  # gained a `caller` field, and `try_start` also gained `kind` ("try" or
  # the older "catch"). Rules used to recover a call's caller by joining
  # `instruction(id, caller, _, _)` — twelve of the fourteen
  # `instruction(...)` uses in the rule corpus were exactly that decode —
  # which made the largest and most volatile relation in the schema an
  # input to stage 0 and to every analysis downstream of the call graph.
  # Same principle as v8, one level up: an instruction ID is positional, so
  # anything derivable from it that a rule needs should be a column.
  # Version 11: `call_followed_by_branch` — a call with some branch later in
  # the same function. unsafe_task computed this by joining `instruction` to
  # itself to compare two indexes, which made it the last analysis reading
  # that relation and by far the most expensive one. Computing it in the
  # emitter, where indexes already exist, is the same v8 principle again:
  # positional questions get answered where the positions live, and only
  # their answers cross into Datalog. NO analysis reads `instruction` now.
  # Version 12: `recv_start` gains `caller` and `blocking`. Same reasoning as
  # v10 and v11 — a rule wanting the function containing a receive had to
  # join `instruction`, and whether the receive can block forever is only
  # visible by following its fail label to a `wait` or `wait_timeout`, which
  # is a positional question the emitter can answer and a rule cannot.
  # Version 13: `send_msg` and `make_fun` gain `caller`; the new
  # `dynamic_call` records a call through a fun value or `apply`, which the
  # call graph cannot follow. Layer 2 gains `pure_contract`, `impure_call`,
  # `protocol_dispatch` and `unknown_call` for the purity analysis — the
  # first analysis here that verifies a claim the author made rather than
  # hunting a bug nobody declared absent, and so the first that has to be
  # sound. `dynamic_call` exists precisely so it can say "unprovable"
  # instead of quietly answering as though the call were not there.
  # Version 14: `impure_call` gains `mode` (read or write). One dimension
  # could not distinguish a config read from an HTTP POST, so every contract
  # had to forbid both or neither — and the transaction analysis reported
  # `Application.get_env/2` as an unrollbackable effect. Purity still rejects
  # both modes; contracts about reversibility look at writes only.
  # Version 15: `callback_return` and `callback_retains_from`. A handle_call
  # that returns `{:noreply, _}` promises to reply later, and the only thing
  # that can discharge it is the `from` it was handed. Both halves are plain
  # bytecode — the return tag is a literal atom in a tuple built immediately
  # before `return`, and keeping `from` is exactly whether {x,1} is ever
  # mentioned — but neither is derivable from any existing relation, because
  # both are questions about a function's shape rather than its calls.
  # Version 16: `tls_verification` and `tls_connect`. Encryption without
  # authentication is not security, and whether a TLS session verifies its
  # peer is a literal in an option list — exactly detectable. The second
  # relation exists for the shape a search cannot find: a connect whose
  # literal options never mention `verify` at all, taking whatever the
  # library defaults to.
  @schema_version 16

  # Layer 1: Module-level facts.

  @module_info %{
    name: :module_info,
    layer: 1,
    fields: [
      {:mod, :symbol, "module name"},
      {:name, :symbol, "module name (repeated for queries)"}
    ],
    doc: "Module existence."
  }

  @function_def %{
    name: :function_def,
    layer: 1,
    fields: [
      {:func, :func_id, "function ID (mod:name/arity)"},
      {:mod, :symbol, "module name"},
      {:name, :symbol, "function name"},
      {:arity, :number, "function arity"},
      {:exported, :number, "1 if exported, 0 if local"}
    ],
    doc: "Function definition within a module."
  }

  # The entry label lives apart from function_def on purpose. It is a label
  # NUMBER, so it shifts whenever anything earlier in the module changes —
  # which made every row of function_def churn on any edit, even though no
  # Datalog rule has ever bound the column (all 55 uses wildcard it). Only
  # `Argus.Cfg` needs it, to root the control-flow graph. Splitting it out
  # keeps function_def stable under body edits, so a consumer memoizing per
  # relation can tell that editing one function cannot have changed a
  # conclusion drawn from another's signature. Same reasoning as keeping
  # line_info out of the semantic fact set.
  @function_entry %{
    name: :function_entry,
    layer: 1,
    fields: [
      {:func, :func_id, "function ID (mod:name/arity)"},
      {:entry, :label, "entry label number"}
    ],
    doc: "Entry label of a function — positional, split from function_def."
  }

  @import_ref %{
    name: :import_ref,
    layer: 1,
    fields: [
      {:mod, :symbol, "imported module"},
      {:name, :symbol, "imported function name"},
      {:arity, :number, "imported function arity"}
    ],
    doc: "External function referenced by the module."
  }

  @module_attribute %{
    name: :module_attribute,
    layer: 1,
    fields: [
      {:mod, :symbol, "module name"},
      {:key, :symbol, "attribute key"},
      {:val, :symbol, "attribute value (stringified)"}
    ],
    doc: "Module attribute key-value pair."
  }

  # Layer 1: Instruction-level facts.

  @instruction %{
    name: :instruction,
    layer: 1,
    fields: [
      {:id, :instr_id, "unique instruction ID"},
      {:func, :func_id, "containing function ID"},
      {:idx, :number, "instruction index within function"},
      {:op, :symbol, "opcode name"}
    ],
    doc: "Every instruction in every function."
  }

  @next %{
    name: :next,
    layer: 1,
    fields: [
      {:from, :instr_id, "instruction ID"},
      {:to, :instr_id, "next instruction ID (fallthrough)"}
    ],
    doc: "Sequential (fallthrough) instruction ordering."
  }

  # Layer 1: Register / data flow facts.

  @move %{
    name: :move,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:src, :symbol, "source operand"},
      {:dst, :symbol, "destination operand"}
    ],
    doc: "Data move from source to destination."
  }

  @def_rel %{
    name: :def,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:reg, :symbol, "defined register"}
    ],
    doc: "Register definition (write)."
  }

  @use_rel %{
    name: :use,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:reg, :symbol, "used register"}
    ],
    doc: "Register use (read)."
  }

  @literal_value %{
    name: :literal_value,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:reg, :symbol, "destination register"},
      {:val, :symbol, "literal value (stringified)"}
    ],
    doc: "Literal value loaded into a register."
  }

  # Layer 1: Control flow facts.

  @jump %{
    name: :jump,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:target, :label, "target label number"}
    ],
    doc: "Unconditional jump to a label."
  }

  @branch %{
    name: :branch,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:fail, :label, "the branch's label edge; falls through otherwise"},
      {:reserved, :number, "always 0 (kept for arity stability)"}
    ],
    doc:
      "Conditional two-way control transfer: the label edge plus fallthrough. " <>
        "For test instructions the label is the fail edge; for receive-loop " <>
        "control (loop_rec, wait_timeout) it is the empty-mailbox/loop-again edge."
  }

  @label_at %{
    name: :label_at,
    layer: 1,
    fields: [
      {:label, :label, "label number"},
      {:id, :instr_id, "instruction ID of the label"}
    ],
    doc: "Maps a label number to the instruction at that position."
  }

  @select_branch %{
    name: :select_branch,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:val, :symbol, "matched value (stringified)"},
      {:target, :label, "target label number"}
    ],
    doc: "One arm of a select_val or select_tuple_arity."
  }

  # Layer 1: Call facts.

  @local_call %{
    name: :local_call,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:target, :symbol, "target label or MFA string"},
      {:arity, :number, "call arity"}
    ],
    doc: "Call to a local (same-module) function by label or MFA."
  }

  @remote_call %{
    name: :remote_call,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:mod, :symbol, "target module"},
      {:func, :symbol, "target function"},
      {:arity, :number, "call arity"}
    ],
    doc: "Call to an external (remote) function."
  }

  @tail_call_rel %{
    name: :tail_call,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"}
    ],
    doc: "Marks an instruction as a tail call."
  }

  @call_followed_by_branch %{
    name: :call_followed_by_branch,
    layer: 1,
    fields: [
      {:id, :instr_id, "call instruction ID"}
    ],
    doc: """
    A call instruction with at least one branch (a `test` or `loop_rec`) \
    later in the same function.

    This is positional information, computed where positional information \
    belongs: in the emitter, which already knows every instruction's index. \
    The alternative is what `unsafe_task` used to do — join `instruction` \
    twice to compare two indexes — which dragged the largest and most \
    volatile relation in the schema into that analysis's input set to \
    answer a yes/no question about ordering.

    Deliberately a coarse predicate, because the rule it serves is coarse: \
    "some branch occurs after this call" is a weak proxy for "the call's \
    result was pattern-matched", and it fires on a branch anywhere later in \
    the function including one in an unrelated clause. Encoding it faithfully \
    keeps findings identical; sharpening it is a separate, deliberate change.
    """
  }

  @bif_call %{
    name: :bif_call,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:mod, :symbol, "BIF module"},
      {:func, :symbol, "BIF function"},
      {:arity, :number, "BIF arity"},
      {:fail, :label, "failure label (0 = no fail)"}
    ],
    doc: "Built-in function call."
  }

  # Layer 1: BEAM-specific facts.

  @allocate %{
    name: :allocate,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:stack, :number, "stack words allocated"},
      {:live, :number, "live X registers"}
    ],
    doc: "Stack frame allocation."
  }

  @deallocate %{
    name: :deallocate,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:stack, :number, "stack words deallocated"}
    ],
    doc: "Stack frame deallocation."
  }

  @send_msg %{
    name: :send_msg,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"}
    ],
    doc: "Message send instruction."
  }

  @recv_start %{
    name: :recv_start,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:blocking, :number, "1 when the receive has no timeout and can block forever"},
      {:fail, :label, "failure label"}
    ],
    doc: """
    Start of a receive loop (loop_rec).

    `blocking` distinguishes the two shapes a receive compiles to. The \
    loop_rec's fail label leads to the empty-mailbox block, which ends in \
    either `wait` (re-enter the loop and sleep — no timeout, so the process \
    can block forever) or `wait_timeout` (bounded). That distinction is only \
    visible by following a label to another instruction, so it is resolved \
    in the emitter and recorded here rather than left for a rule to \
    reconstruct.
    """
  }

  @recv_end %{
    name: :recv_end,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"}
    ],
    doc: "End of a receive clause (remove_message)."
  }

  @spawn_call %{
    name: :spawn_call,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:mod, :symbol, "spawned module"},
      {:func, :symbol, "spawned function"},
      {:arity, :number, "spawned function arity"},
      {:variant, :symbol, "spawn variant (spawn, spawn_link, spawn_monitor)"}
    ],
    doc: "Process spawn detected via erlang:spawn* calls."
  }

  @try_start %{
    name: :try_start,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:kind, :symbol, "\"try\" or \"catch\" (the older syntax)"},
      {:handler, :label, "handler label"}
    ],
    doc: "Start of a try block."
  }

  @try_end %{
    name: :try_end,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"}
    ],
    doc: "End of a try block."
  }

  @dynamic_call %{
    name: :dynamic_call,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:kind, :symbol, "call_fun (a fun value) or apply (a computed MFA)"}
    ],
    doc: """
    A call whose target is not statically known: through a fun value \
    (`call_fun`), or through a computed module/function (`apply`).

    The call graph cannot follow these, which makes them the boundary of \
    anything that reasons over reachability. Most analyses can ignore that \
    and be merely incomplete; one that makes a claim about ALL executions — \
    that a function performs no side effects, say — cannot, because an \
    unfollowable call could do anything. Recorded so such an analysis can \
    say "unprovable here" instead of quietly answering as though the call \
    were not there.
    """
  }

  @make_fun %{
    name: :make_fun,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:caller, :func_id, "containing function ID"},
      {:target, :symbol,
       "lambda body label number, or the function ID for funs over named functions"},
      {:num_free, :number, "number of captured variables"}
    ],
    doc: "Lambda/closure creation."
  }

  @closure_def %{
    name: :closure_def,
    layer: 1,
    fields: [
      {:parent_func, :func_id, "function constructing the closure"},
      {:closure_func, :func_id, "function ID of the closure body"}
    ],
    doc: """
    Closure construction edge: `parent_func` builds a closure pointing at \
    `closure_func`. Treated as a static call edge in the call graph so that \
    `call_reachable` follows execution into closure bodies passed to \
    higher-order callees (`Enum.map`, `:telemetry.span`, `Task.async`, etc.).

    Only emitted when the `make_fun3` target is a concrete `{Mod, Func, Arity}` \
    triple. Closures targeting raw labels (rare in modern BEAM) are skipped \
    because we don't have the closure's function ID at emit time.
    """
  }

  @tuple_field_access %{
    name: :tuple_field_access,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:src, :symbol, "source tuple register"},
      {:idx, :number, "extracted field index (0-based)"},
      {:dst, :symbol, "destination register holding the extracted field"}
    ],
    doc: """
    Records the index of a `get_tuple_element` extraction. Lets analyses \
    that follow pattern-matched destructuring (e.g. `{:ok, val} = call()`) \
    know which field of the source tuple was placed in the destination.
    """
  }

  @type_test %{
    name: :type_test,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:test, :symbol, "type test name (is_integer, is_atom, is_tuple, ...)"},
      {:src, :symbol, "register being type-tested"},
      {:fail, :label, "fail label if the test does not hold (0 = fallthrough)"}
    ],
    doc: """
    Type-test instructions emitted by the compiler for guard and \
    pattern-match narrowing (`is_integer`, `is_tuple`, and the structural \
    `is_nonempty_list`/`is_tagged_tuple`, whose extra operands are not \
    recorded — `src` is always the tested register). Captures the test \
    name (which the generic `branch` fact discards) so type-narrowing \
    dataflow analyses can reason about which register has which inferred \
    type on the success edge.
    """
  }

  @unhandled_op %{
    name: :unhandled_op,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:op, :symbol, "BEAM opcode name that the emitter did not specialize"}
    ],
    doc: """
    Records every instruction that fell through to the catch-all clause in \
    `Argus.Pipeline.Emit`. Used for offline auditing — running this against \
    a real corpus surfaces opcodes Argus is silently dropping (e.g. \
    pre-OTP-24 instruction shapes still emitted by older compilers).
    """
  }

  @bs_start %{
    name: :bs_start,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:fail, :label, "failure label"}
    ],
    doc: "Start of binary matching."
  }

  @line_info %{
    name: :line_info,
    layer: 1,
    fields: [
      {:id, :instr_id, "instruction ID"},
      {:line, :number, "source line number"}
    ],
    doc: """
    The source line in effect at this instruction: line markers are \
    resolved through the Line chunk at emit time and stamped onto every \
    following instruction until the next marker, so any instruction ID \
    an anchor names resolves to its exact line. Instructions with no \
    line in effect — before the first marker, under a no-location marker \
    (reference 0, on compiler-generated code), or in modules without a \
    parseable Line chunk — emit no rows.
    """
  }

  # Layer 2: Supervision extractor facts.

  @supervisor %{
    name: :supervisor,
    layer: 2,
    fields: [
      {:mod, :symbol, "supervisor module"},
      {:strategy, :symbol, "restart strategy"}
    ],
    doc: "Module that implements the Supervisor behaviour."
  }

  # The tree-definition site is where a FINDING should be anchored, not
  # something the logic joins on — so it lives apart from `supervisor`. It
  # is an instruction ID, which renumbers whenever anything earlier in the
  # supervisor's init shifts; keeping it in `supervisor` made every rule
  # that merely asks "is this module a supervisor, and with what strategy"
  # churn on unrelated edits. Analyses that anchor a finding at the tree
  # definition join this relation explicitly and accept that coupling.
  @supervisor_site %{
    name: :supervisor_site,
    layer: 2,
    fields: [
      {:mod, :symbol, "supervisor module"},
      {:site, :symbol,
       "instruction ID of the Supervisor.init/start_link call (or Erlang-style " <>
         "flags literal) that defines the tree — the strategy line; 'dynamic' " <>
         "when not statically found"}
    ],
    doc: "Anchor site of a supervisor's tree definition — positional."
  }

  @supervisor_child %{
    name: :supervisor_child,
    layer: 2,
    fields: [
      {:sup, :symbol, "supervisor module"},
      {:position, :number, "child start order"},
      {:child_mod, :symbol, "child module"},
      {:restart, :symbol, "restart type (permanent/transient/temporary)"},
      {:type, :symbol, "child type (worker/supervisor)"}
    ],
    doc: "Child specification within a supervisor."
  }

  @supervisor_child_form %{
    name: :supervisor_child_form,
    layer: 2,
    fields: [
      {:sup, :symbol, "supervisor module"},
      {:position, :number, "child start order — matches the paired supervisor_child.position"},
      {:form, :symbol, "'explicit' | 'shorthand'"}
    ],
    doc: """
    Whether a child spec stated its `type`, or whether \
    `supervisor_child.type` is the extractor's default.

    The `{Module, args}` and bare-`Module` forms state nothing: \
    `Module.child_spec/1` decides, and `use Supervisor` generates \
    `type: :supervisor` where the default written here is `worker`. Any \
    rule reading `type` must join this, or it is reasoning about a guess — \
    a first attempt at "supervisor registered as a worker" reported 26 \
    modules on the corpus and every one was this artefact.
    """
  }

  @supervisor_child_name %{
    name: :supervisor_child_name,
    layer: 2,
    fields: [
      {:sup, :symbol, "supervisor module"},
      {:position, :number, "child start order — matches the paired supervisor_child.position"},
      {:name, :symbol, "registered name from the child spec's :name option"}
    ],
    doc: """
    Registered name declared in a child spec's `:name` option — e.g. \
    the `MyApp.Pool` in `{DynamicSupervisor, name: MyApp.Pool}`. Recorded \
    alongside `supervisor_child` (same `sup`/`position`) so a \
    `dynamic_child` whose parent is a registered name can be anchored to \
    the child that registers it: a `DynamicSupervisor.start_child(MyApp.Pool, _)` \
    call resolves to the named child instead of appearing unanchored. \
    Only atom names are recorded — `{:via, _, _}` and `{:global, _}` names \
    are not, since name-based `start_child` targets are always atoms.
    """
  }

  @monitor_call %{
    name: :monitor_call,
    layer: 2,
    fields: [
      {:id, :symbol, "the call site"},
      {:func, :symbol, "the monitoring function"},
      {:target, :symbol, "the monitored target, or 'dynamic'"}
    ],
    doc: """
    A `Process.monitor/1` or `:erlang.monitor/2`. Once it returns, a \
    `{:DOWN, ref, :process, object, reason}` arrives unless cancelled — so \
    a process that monitors is a process that receives `:DOWN`.
    """
  }

  @demonitor_call %{
    name: :demonitor_call,
    layer: 2,
    fields: [
      {:id, :symbol, "the call site"},
      {:func, :symbol, "the cancelling function"},
      {:flush, :symbol, "'flush' | 'no_flush'"}
    ],
    doc: """
    A `Process.demonitor/1,2`. `flush` records whether `[:flush]` was \
    passed, which is the difference between cancelling a future message and \
    removing one already in the mailbox. Unreadable options are recorded as \
    `no_flush`, the direction that keeps a finding rather than discharging \
    one on a guess.
    """
  }

  @http_route %{
    name: :http_route,
    layer: 2,
    fields: [
      {:router, :symbol, "the router module"},
      {:verb, :symbol, "the HTTP method"},
      {:path, :symbol, "the route path, with its placeholders"},
      {:plug, :symbol, "the controller or LiveView"},
      {:action, :symbol, "the action or live action"}
    ],
    doc: """
    A route from `Phoenix.Router.__routes__/0`. `pipe_through` is absent \
    because Phoenix compiles pipelines into the dispatch function rather \
    than into this literal, so whether a route is authenticated is \
    derivable but not from here.
    """
  }

  @schema_field %{
    name: :schema_field,
    layer: 2,
    fields: [
      {:mod, :symbol, "the schema module"},
      {:field, :symbol, "a persisted field"}
    ],
    doc: "A field on an Ecto schema, read from the literal in __schema__/1."
  }

  @redacted_field %{
    name: :redacted_field,
    layer: 2,
    fields: [
      {:mod, :symbol, "the schema module"},
      {:field, :symbol, "a field declared redact: true"}
    ],
    doc: """
    A field Ecto excludes from `inspect/1`. Absence is the interesting \
    case — `redact` defaults to off — so consumers ask by negation.
    """
  }

  @socket_transport %{
    name: :socket_transport,
    layer: 2,
    fields: [
      {:endpoint, :symbol, "the Phoenix endpoint module"},
      {:path, :symbol, "the socket's mount path"},
      {:transport, :symbol, "'websocket' | 'longpoll'"}
    ],
    doc: """
    A socket transport an endpoint enables, read from the literal that \
    `socket/3` compiles into `__sockets__/0`. Emitted only for transports \
    that are present and not `false`, which is how Phoenix reads them.
    """
  }

  @supervisor_max_children %{
    name: :supervisor_max_children,
    layer: 2,
    fields: [
      {:sup, :symbol, "the DynamicSupervisor module"},
      {:limit, :symbol, "the configured cap"}
    ],
    doc: """
    A `max_children` cap read from `DynamicSupervisor.init/1`'s literal \
    options. Present ONLY when a finite cap is set: the behaviour defaults \
    to `:infinity`, so absence is the common case and the interesting one, \
    and consumers ask about it by negation.
    """
  }

  @dynamic_child %{
    name: :dynamic_child,
    layer: 2,
    fields: [
      {:sup, :symbol, "supervisor module (or 'dynamic' if not statically resolvable)"},
      {:child_mod, :symbol, "child module being started"},
      {:caller_func, :symbol, "function that calls start_child"}
    ],
    doc: """
    Runtime-spawned child via `DynamicSupervisor.start_child/2`. Captured \
    so analyses like `one_for_one_coupling` can see workers added at \
    runtime (connection pools, per-tenant supervisors, plugin systems) \
    that wouldn't appear in any static `init/1` child spec scan.
    """
  }

  @named_process %{
    name: :named_process,
    layer: 2,
    fields: [
      {:mod, :symbol, "module"},
      {:name, :symbol, "registered process name"}
    ],
    doc: "Named process registration detected in code."
  }

  @process_link %{
    name: :process_link,
    layer: 2,
    fields: [
      {:from_mod, :symbol, "linking module"},
      {:to_mod, :symbol, "linked module"}
    ],
    doc: "Process link between modules."
  }

  # Layer 2: OTP pattern extractor facts.

  @implements_behaviour %{
    name: :implements_behaviour,
    layer: 2,
    fields: [
      {:mod, :symbol, "implementing module"},
      {:behaviour, :symbol, "behaviour module"}
    ],
    doc: "Module implements a specific OTP behaviour."
  }

  @sync_call %{
    name: :sync_call,
    layer: 2,
    fields: [
      {:caller_func, :symbol, "calling function ID"},
      {:callee_mod, :symbol, "target GenServer module"}
    ],
    doc: "GenServer.call target detected in code."
  }

  @async_cast %{
    name: :async_cast,
    layer: 2,
    fields: [
      {:caller_func, :symbol, "calling function ID"},
      {:callee_mod, :symbol, "target GenServer module"}
    ],
    doc: "GenServer.cast target detected in code."
  }

  @sync_call_timeout %{
    name: :sync_call_timeout,
    layer: 2,
    fields: [
      {:caller_func, :symbol, "calling function ID"},
      {:callee_mod, :symbol, "target GenServer module"},
      {:timeout_ms, :number, "timeout in ms (-1=infinity, 0=dynamic)"}
    ],
    doc: "GenServer.call timeout value at call site."
  }

  @init_continues_to %{
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
  }

  @handle_continue_clause %{
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

  @callback_return %{
    name: :callback_return,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID of the tuple construction"},
      {:func, :symbol, "the callback function"},
      {:callback, :symbol, "callback name: 'handle_call' | 'init' | ..."},
      {:tag, :symbol, "the literal return tag, e.g. ':reply' | ':noreply' | ':stop'"}
    ],
    doc: """
    A literal return tag of an OTP callback — the first element of a tuple \
    built into {x,0} immediately before `return`. Absent when the callback \
    tail-calls, since the shape then belongs to the callee; consumers must \
    treat absence as unknown rather than as "returns nothing".
    """
  }

  @callback_drops_from %{
    name: :callback_drops_from,
    layer: 2,
    fields: [
      {:id, :symbol, "the {:noreply, _} return site"},
      {:func, :symbol, "the handle_call/3 function"}
    ],
    doc: """
    A `{:noreply, _}` return site in handle_call/3 that some execution \
    reaches having never read `from`. Per site rather than per function, \
    because handle_call compiles every clause into one function and a \
    sibling clause that defers correctly would otherwise vouch for one \
    that does not.

    Established by walking the intra-function block graph from the entry \
    across blocks that do not read `from`. `from` arrives in {x,1}, and a \
    read is either a mention of that register or a call of arity two or \
    more, since calls take arguments positionally and a body passing \
    `from` straight through compiles to no move at all.
    """
  }

  @tls_verification %{
    name: :tls_verification,
    layer: 2,
    fields: [
      {:id, :symbol, "the instruction"},
      {:func, :symbol, "the function"},
      {:setting, :symbol, "'none' | 'peer' | 'absent'"}
    ],
    doc: """
    How a TLS session verifies its peer, read from literal option lists and \
    bare atoms. `absent` means a connect supplied literal options that never \
    mention `verify`, so the library's default applies — Erlang's `:ssl` \
    client verified nothing at all before OTP 26.
    """
  }

  @tls_connect %{
    name: :tls_connect,
    layer: 2,
    fields: [
      {:id, :symbol, "the instruction"},
      {:func, :symbol, "the calling function"},
      {:api, :symbol, "the connect API"},
      {:opts, :symbol, "how options were supplied: 'literal' | 'dynamic'"}
    ],
    doc: """
    A call establishing a TLS session. `dynamic` options are recorded as \
    such rather than guessed at: a false "this is insecure" on a call that \
    configures itself properly is worse than silence.
    """
  }

  @deferred_reply %{
    name: :deferred_reply,
    layer: 2,
    fields: [
      {:handler_func, :symbol, "function calling GenServer.reply/2"},
      {:from_arg, :symbol, "resolution of the from argument: 'arg:N' | 'state_field' | 'dynamic'"}
    ],
    doc: """
    Records `GenServer.reply/2` call sites — the deferred-reply pattern \
    where a handle_call clause stores the from reference and replies later \
    from a different callback (handle_info, handle_continue, an awaited \
    Task). No analysis consumes this fact yet; it's infrastructure for \
    future timeout-window analysis where the original caller's GenServer.call \
    timeout has to cover the entire delayed-reply path.
    """
  }

  @delayed_message %{
    name: :delayed_message,
    layer: 2,
    fields: [
      {:sender_func, :symbol, "function calling send_after / apply_after"},
      {:target, :symbol, "target resolution: 'self' | inspected name | 'dynamic'"},
      {:message, :symbol, "stringified message pattern (atom literal or 'dynamic')"}
    ],
    doc: """
    Records `Process.send_after/3,4`, `:timer.send_after/2,3`, and \
    `:timer.apply_after/4` as implicit message sources. These functions \
    cause a `handle_info/2` callback to fire later — invisible to the \
    static call graph until we connect the message pattern to its \
    matching handler clause.
    """
  }

  @gen_event_handler %{
    name: :gen_event_handler,
    layer: 2,
    fields: [
      {:event_mgr, :symbol, "event manager (the gen_event process)"},
      {:handler_mod, :symbol, "module added as a handler"}
    ],
    doc: """
    Records `:gen_event.add_handler(Manager, Handler, Args)` registrations \
    so analyses can reason about which handler modules belong to which \
    event manager.
    """
  }

  @sync_call_via %{
    name: :sync_call_via,
    layer: 2,
    fields: [
      {:caller_func, :symbol, "calling function ID"},
      {:registry, :symbol, "registry module from the {:via, _, _} tuple"},
      {:key, :symbol, "registry key (e.g. :worker_a or a module atom)"}
    ],
    doc: """
    Sync call whose target was constructed as a `{:via, Registry, {reg, key}}` \
    tuple — the OTP extractor can't reduce this to a single callee module \
    without consulting the registry, so it emits the via shape and lets \
    Datalog rules cross-reference with `process_register` / `via_tuple` facts.
    """
  }

  # Layer 2: ETS extractor facts.

  @ets_new %{
    name: :ets_new,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID of the :ets.new/2 call"},
      {:func, :symbol, "containing function ID"},
      {:name, :symbol, "table name atom (or \"dynamic\")"}
    ],
    doc: "ETS table creation point."
  }

  @ets_option %{
    name: :ets_option,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID (same as ets_new)"},
      {:key, :symbol, "option category"},
      {:value, :symbol, "option value as string"}
    ],
    doc: "Parsed option from :ets.new/2."
  }

  @ets_op %{
    name: :ets_op,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:table_ref, :symbol, "table name atom (or \"dynamic\")"},
      {:op, :symbol, "ETS function name"},
      {:kind, :symbol, "read, write, or delete"}
    ],
    doc: "ETS read/write/delete operation."
  }

  @port_open %{
    name: :port_open,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID of the port-opening call"},
      {:func, :symbol, "containing function ID"},
      {:mechanism, :symbol,
       "how the port is opened: \"Port.open\", \"erlang.open_port\", " <>
         "\"System.cmd\", \"System.shell\", or \"os.cmd\""},
      {:target, :symbol, "the spawned command / executable / driver, or \"dynamic\""}
    ],
    doc:
      "Port creation point. A port is owned by the opening process and dies " <>
        "when it terminates — so, like an ETS table, it attributes to that " <>
        "process in the supervision tree."
  }

  # Layer 2: Atom safety extractor facts.

  @unsafe_atom_creation %{
    name: :unsafe_atom_creation,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:api, :symbol, "API name (e.g. String.to_atom/1)"}
    ],
    doc: "Unsafe atom creation from dynamic input."
  }

  @unsafe_deserialization %{
    name: :unsafe_deserialization,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:api, :symbol, "API name"},
      {:safety, :symbol, "safe or unsafe"}
    ],
    doc: "Binary-to-term deserialization call with safety classification."
  }

  @code_execution %{
    name: :code_execution,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:api, :symbol, "API name (e.g. Code.eval_string/1)"}
    ],
    doc: "Dynamic code execution or OS command call."
  }

  # Layer 2: Error handling extractor facts.

  @bare_rescue %{
    name: :bare_rescue,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID of try_start"},
      {:func, :symbol, "containing function ID"}
    ],
    doc: "Try/catch handler that catches all exceptions without filtering or reraising."
  }

  @trap_exit %{
    name: :trap_exit,
    layer: 2,
    fields: [
      {:func, :symbol, "containing function ID"},
      {:mod, :symbol, "module name"}
    ],
    doc: "Process.flag(:trap_exit, true) call site."
  }

  @exit_call %{
    name: :exit_call,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:target, :symbol, "exit target (pid or dynamic)"}
    ],
    doc: "Explicit Process.exit/2 or :erlang.exit/1,2 call."
  }

  @ignored_error_result %{
    name: :ignored_error_result,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:callee, :symbol, "called function returning {:ok,_}|{:error,_}"}
    ],
    doc: "Call to function returning tagged tuple where result is not pattern matched."
  }

  # Layer 2: Process registry & naming extractor facts.

  @process_register %{
    name: :process_register,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:name, :symbol, "registered name atom"},
      {:method, :symbol, "registration method (register, start_link, start)"}
    ],
    doc: "Process name registration."
  }

  @registry_op %{
    name: :registry_op,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:registry, :symbol, "registry module"},
      {:op, :symbol, "operation (register, lookup, dispatch, etc.)"},
      {:key, :symbol, "registry key"}
    ],
    doc: "Registry module operation."
  }

  @via_tuple %{
    name: :via_tuple,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:registry, :symbol, "registry module"},
      {:key, :symbol, "registry key"}
    ],
    doc: "{:via, Registry, {reg, key}} tuple construction."
  }

  @whereis_call %{
    name: :whereis_call,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:name, :symbol, "process name"}
    ],
    doc: "Process.whereis/1 or :erlang.whereis/1 call."
  }

  # Layer 2: Distributed systems extractor facts.

  @rpc_call %{
    name: :rpc_call,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:variant, :symbol, "RPC variant (rpc, erpc, multicall)"},
      {:timeout, :symbol, "timeout value (ms, infinity, or dynamic)"}
    ],
    doc: "RPC call with timeout information."
  }

  @global_register %{
    name: :global_register,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:name, :symbol, "global name"},
      {:arity, :symbol,
       "call arity: '2' (default conflict resolution) or '3' (explicit resolver)"}
    ],
    doc: """
    `:global.register_name` call. Arity distinguishes the race-prone \
    default (`/2`) from a call that supplies its own conflict-resolution \
    function (`/3`).
    """
  }

  @global_op %{
    name: :global_op,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:op, :symbol, "operation: set_lock | trans | del_lock | whereis_name | send"},
      {:retries, :symbol, "retry count: \"infinity\" | \"0\" | integer | \"dynamic\""}
    ],
    doc: """
    `:global` synchronization primitives. The retries field is the third \
    argument of `:global.set_lock/3` (or `:global.trans/4`); analyses use \
    it to distinguish blocking calls (`infinity` or large positive \
    integers) from non-blocking try-once calls (`0`).

    `:global.set_lock/2` and `:global.trans/2,3` default to infinity \
    retries — recorded as `"infinity"` even when the source code omits \
    the argument.
    """
  }

  @node_operation %{
    name: :node_operation,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:op, :symbol, "operation (connect, disconnect, spawn, ping, etc.)"}
    ],
    doc: "Node or :net_kernel operation."
  }

  @distributed_store_op %{
    name: :distributed_store_op,
    layer: 2,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:store, :symbol, "store type (mnesia or dets)"},
      {:op, :symbol, "operation name"}
    ],
    doc: "Mnesia or DETS distributed store operation."
  }

  # Layer 2: gen_statem extractor facts.

  @statem_module %{
    name: :statem_module,
    layer: 2,
    fields: [
      {:mod, :symbol, "module name"},
      {:callback_mode, :symbol, "state_functions or handle_event_function"}
    ],
    doc: "Module implementing gen_statem behaviour."
  }

  @statem_state %{
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
  }

  @statem_initial %{
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
  }

  @statem_transition %{
    name: :statem_transition,
    layer: 2,
    fields: [
      {:mod, :symbol, "module name"},
      {:from_state, :symbol, "source state"},
      {:event, :symbol, "event type"},
      {:to_state, :symbol, "target state"}
    ],
    doc: "State transition in a gen_statem."
  }

  @statem_timeout %{
    name: :statem_timeout,
    layer: 2,
    fields: [
      {:mod, :symbol, "module name"},
      {:state, :symbol, "state setting the timeout"},
      {:type, :symbol, "timeout type (state_timeout, event_timeout, generic)"},
      {:value, :symbol, "timeout value"}
    ],
    doc: "Timeout set in a gen_statem state."
  }

  # Coverage / precision instrumentation. Populated only when the active
  # analysis run has imprecision tracking enabled (i.e. running the
  # `coverage` analysis).

  @imprecision %{
    name: :imprecision,
    layer: 2,
    fields: [
      {:category, :symbol,
       "what we were trying to resolve (e.g. genserver_callee, ets_table_name)"},
      {:func, :symbol, "function ID where the fallback occurred"},
      {:relation, :symbol, "the fact relation that received the dynamic placeholder"},
      {:reason, :symbol, "why imprecision: dynamic | unresolvable | skipped | missing"}
    ],
    doc: """
    Tracks every fallback to a "dynamic" placeholder or an outright \
    skipped fact emission. Populated only when imprecision tracing is \
    enabled for the current pipeline run — the `coverage` analysis turns \
    it on, every other analysis runs with tracing off and produces no \
    rows in this relation.

    The `category` vocabulary is documented in `lib/argus/extractor/helpers.ex` \
    and is treated as a versioned API: changes are noted in CHANGELOG so \
    coverage diff tooling can keep stable keys.
    """
  }

  @pure_contract %{
    name: :pure_contract,
    layer: 2,
    fields: [
      {:func, :func_id, "the function declared pure"},
      {:mod, :symbol, "declaring module"},
      {:name, :symbol, "function name"},
      {:arity, :number, "function arity"}
    ],
    doc: """
    A function its module declared free of observable effects with \
    `@pure true` (see `Argus.Purity`).

    Read out of the beam's persisted attribute chunk, so the contract comes \
    from the compiled artifact and cannot drift from the code it describes.
    """
  }

  @protocol_dispatch %{
    name: :protocol_dispatch,
    layer: 2,
    fields: [
      {:id, :instr_id, "instruction ID of the call"},
      {:caller, :func_id, "containing function ID"},
      {:api, :symbol, "the protocol function called"}
    ],
    doc: """
    A call that dispatches through a protocol, so its target is whichever \
    implementation the argument's type provides.

    Distinct from `unknown_call`: that one means the effect model has no \
    entry, which somebody could add. This one means there is no single \
    answer to have — any module may define an implementation, and it is \
    ordinary code that can do anything.
    """
  }

  @impure_call %{
    name: :impure_call,
    layer: 2,
    fields: [
      {:id, :instr_id, "instruction ID of the call"},
      {:caller, :func_id, "containing function ID"},
      {:api, :symbol, "the API called, as Mod.fun/arity"},
      {:category, :symbol,
       "io | logging | process | process_dict | ets | port | node | time | random | network | code_loading"},
      {:mode, :symbol, "read (observes state) or write (changes it)"}
    ],
    doc: """
    A call with a known observable effect, classified by \
    `Argus.Purity.Effects`. The category says WHAT the effect is; the mode \
    says whether it changes anything.

    Both dimensions are needed because contracts differ in what they \
    forbid. Purity rejects reads and writes alike — `Application.get_env/2` \
    already breaks referential transparency. A transaction body only cares \
    about writes: a config read has nothing to roll back, while an HTTP \
    POST has already left the machine. One dimension would force every \
    config read to be reported as a transaction hazard.
    """
  }

  @resolved_apply %{
    name: :resolved_apply,
    layer: 2,
    fields: [
      {:id, :instr_id, "instruction ID of the apply"},
      {:caller, :func_id, "containing function ID"},
      {:target, :func_id, "the MFA it actually calls"}
    ],
    doc: """
    An `apply/3` whose module and function arguments resolve to literals, \
    so the call target is statically known after all.

    `apply` is only opaque when M and F are genuinely unknown. When they are \
    constants — which is most uses, since apply is usually reached through a \
    macro or a dispatch table with constant entries — it is a static call \
    wearing a disguise, and analyses that would otherwise give up can carry \
    on to the real target.
    """
  }

  @unknown_call %{
    name: :unknown_call,
    layer: 2,
    fields: [
      {:id, :instr_id, "instruction ID of the call"},
      {:caller, :func_id, "containing function ID"},
      {:api, :symbol, "the API called, as Mod.fun/arity"},
      {:callee, :func_id, "the callee as a function ID, for contract lookup"}
    ],
    doc: """
    A call the effect model has no opinion about — neither known-impure nor \
    known-pure.

    Recorded rather than ignored because purity is a claim about every \
    execution. Assuming unknown calls are harmless would make a \
    verification report success far more often and mean nothing.
    """
  }

  @call_arg %{
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
      {:value, :symbol, "resolved value: literal atom string, or 'dynamic'"}
    ],
    doc: """
    Resolved argument value at a call site. Enables interprocedural \
    constant propagation: Datalog rules in `clientlib/interprocedural.dl` \
    trace literal values from call sites through forwarding chains to \
    derive additional `sync_call`/`async_cast` rows that the extractors \
    couldn't resolve statically. Forwarded parameters are NOT values here \
    — they are their own relation, `call_arg_forward`.
    """
  }

  @call_arg_forward %{
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
  }

  # All relations indexed by name.

  @layer_1_relations [
    @module_info,
    @function_def,
    @function_entry,
    @import_ref,
    @module_attribute,
    @instruction,
    @next,
    @move,
    @def_rel,
    @use_rel,
    @literal_value,
    @jump,
    @branch,
    @label_at,
    @select_branch,
    @local_call,
    @remote_call,
    @tail_call_rel,
    @bif_call,
    @call_followed_by_branch,
    @allocate,
    @deallocate,
    @send_msg,
    @recv_start,
    @recv_end,
    @spawn_call,
    @try_start,
    @try_end,
    @make_fun,
    @dynamic_call,
    @closure_def,
    @tuple_field_access,
    @type_test,
    @unhandled_op,
    @bs_start,
    @line_info
  ]

  @layer_2_relations [
    @supervisor,
    @supervisor_site,
    @supervisor_child,
    @supervisor_child_form,
    @supervisor_child_name,
    @dynamic_child,
    @supervisor_max_children,
    @socket_transport,
    @monitor_call,
    @demonitor_call,
    @http_route,
    @schema_field,
    @redacted_field,
    @named_process,
    @process_link,
    @implements_behaviour,
    @sync_call,
    @async_cast,
    @sync_call_timeout,
    @sync_call_via,
    @delayed_message,
    @callback_return,
    @callback_drops_from,
    @tls_verification,
    @tls_connect,
    @deferred_reply,
    @init_continues_to,
    @handle_continue_clause,
    @gen_event_handler,
    @ets_new,
    @ets_option,
    @ets_op,
    @port_open,
    # Atom safety.
    @unsafe_atom_creation,
    @unsafe_deserialization,
    @code_execution,
    # Error handling.
    @bare_rescue,
    @trap_exit,
    @exit_call,
    @ignored_error_result,
    # Process registry & naming.
    @process_register,
    @registry_op,
    @via_tuple,
    @whereis_call,
    # Distributed systems.
    @rpc_call,
    @global_register,
    @global_op,
    @node_operation,
    @distributed_store_op,
    # gen_statem.
    @statem_module,
    @statem_state,
    @statem_initial,
    @statem_transition,
    @statem_timeout,
    # Interprocedural constant propagation.
    @call_arg,
    @call_arg_forward,
    # Purity contracts and call classification.
    @pure_contract,
    @impure_call,
    @protocol_dispatch,
    @unknown_call,
    @resolved_apply,
    # Coverage instrumentation (populated only by the coverage analysis).
    @imprecision
  ]

  @all_relations @layer_1_relations ++ @layer_2_relations

  @relations_by_name Map.new(@all_relations, fn r -> {r.name, r} end)

  @doc """
  The fact-schema version, asserted by in-process consumers at compile time.

  Bumped whenever a relation is added/removed, any field changes name,
  position, or kind, or a field's meaning changes. Independent of the
  package version.
  """
  @spec version() :: pos_integer()
  def version, do: @schema_version

  @doc """
  Returns all relation definitions.
  """
  @spec all() :: [relation()]
  def all, do: @all_relations

  @doc """
  Returns layer 1 (generic bytecode) relation definitions.
  """
  @spec layer_1() :: [relation()]
  def layer_1, do: @layer_1_relations

  @doc """
  Returns layer 2 (domain extractor) relation definitions.
  """
  @spec layer_2() :: [relation()]
  def layer_2, do: @layer_2_relations

  @doc """
  Looks up a relation by name.
  """
  @spec fetch(atom()) :: {:ok, relation()} | :error
  def fetch(name) do
    case @relations_by_name do
      %{^name => rel} -> {:ok, rel}
      _ -> :error
    end
  end

  @doc """
  Looks up a relation by name, raising if not found.
  """
  @spec fetch!(atom()) :: relation()
  def fetch!(name) do
    case fetch(name) do
      {:ok, rel} -> rel
      :error -> raise ArgumentError, "unknown relation: #{inspect(name)}"
    end
  end

  @doc """
  Returns the number of fields for a relation.
  """
  @spec arity(atom()) :: non_neg_integer()
  def arity(name) do
    fetch!(name) |> Map.fetch!(:fields) |> length()
  end

  @doc """
  Returns field names for a relation.
  """
  @spec field_names(atom()) :: [atom()]
  def field_names(name) do
    fetch!(name) |> Map.fetch!(:fields) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Returns the Souffle type declaration string for a relation.

  The semantic field kinds collapse to their Souffle representation, so the
  `.decl`/`.facts` surface is unchanged by kind enrichment.
  """
  @spec souffle_decl(atom()) :: String.t()
  def souffle_decl(name) do
    rel = fetch!(name)

    fields_str =
      rel.fields
      |> Enum.map(fn {fname, ftype, _doc} -> "#{fname}: #{souffle_type(ftype)}" end)
      |> Enum.join(", ")

    ".decl #{name}(#{fields_str})"
  end

  @doc """
  Renders a complete `.dl` declaration file for a layer.

  Every relation in the layer gets a `.decl` and a matching `.input`, so a
  rules file that includes this never has to declare a fact relation itself.
  Declaring more than a given analysis reads is free: Souffle prunes unused
  *input* relations during compilation, which is why each analysis's true
  input set (`Argus.Analysis.input_relations/1`, read out of the transformed
  RAM) stays narrow regardless of what was declared. Unused *derived*
  relations are not pruned, which is why rule fragments still have to be
  included deliberately.

  Written to disk by `mix argus.gen.dl` and checked byte-for-byte by the
  test suite. Hand-editing the generated files is the failure mode this
  exists to remove: the declarations are positional, and Souffle will not
  notice a field reordered against what the emitter actually writes.

  `layer` is `:layer_1`, `:layer_2`, or `:all`.
  """
  @spec souffle_decls(:layer_1 | :layer_2 | :all) :: String.t()
  def souffle_decls(layer) do
    {relations, title, source} =
      case layer do
        :layer_1 -> {layer_1(), "Layer 1 — generic bytecode facts", "Argus.Schema.layer_1/0"}
        :layer_2 -> {layer_2(), "Layer 2 — domain extractor facts", "Argus.Schema.layer_2/0"}
        :all -> {all(), "All fact relations", "Argus.Schema.all/0"}
      end

    body =
      relations
      |> Enum.sort_by(& &1.name)
      |> Enum.map_join("\n\n", fn rel ->
        """
        #{comment(rel.doc)}
        #{souffle_decl(rel.name)}
        .input #{rel.name}\
        """
      end)

    """
    // #{title}.
    //
    // GENERATED by `mix argus.gen.dl` from #{source} — do not edit.
    // Schema version #{@schema_version}.
    //
    // Include this instead of declaring fact relations by hand. Souffle
    // prunes input relations no rule reads, so including the whole layer
    // costs nothing in the solve.

    #{body}
    """
  end

  # Relation docs are prose and frequently run to several lines. Every line
  # needs its own `//`, or the second line lands in the parser as a bare
  # identifier and the whole program fails to compile.
  defp comment(doc) do
    doc
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> "//"
      line -> "// " <> line
    end)
  end

  defp souffle_type(:symbol), do: :symbol
  defp souffle_type(:instr_id), do: :symbol
  defp souffle_type(:func_id), do: :symbol
  defp souffle_type(:number), do: :number
  defp souffle_type(:label), do: :number

  @doc """
  Returns all relation names.
  """
  @spec names() :: [atom()]
  def names, do: Enum.map(@all_relations, & &1.name)
end
