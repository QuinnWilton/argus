defmodule Argus.Schema.Bytecode do
  @moduledoc """
  Layer-1 bytecode facts: functions, instructions, value flow, control flow, and BEAM \
  operations. `Argus.Pipeline.Emit` produces these relations; `Argus.Schema` exposes \
  them. Relations marked `in_process` are used only by passes running in the VM.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
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
      },

      # Keep the numeric entry label separate from `function_def`: body edits can
      # renumber labels without changing function signatures. Only `Argus.Cfg` needs the
      # label, so other consumers can retain their cached results.
      %{
        name: :function_entry,
        layer: 1,
        in_process: true,
        fields: [
          {:func, :func_id, "function ID (mod:name/arity)"},
          {:entry, :label, "entry label number"}
        ],
        doc: "Entry label of a function — positional, split from function_def."
      },
      %{
        name: :instruction,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "unique instruction ID"},
          {:func, :func_id, "containing function ID"},
          {:idx, :number, "instruction index within function"},
          {:op, :symbol, "opcode name"}
        ],
        doc: "Every instruction in every function."
      },
      %{
        name: :next,
        layer: 1,
        in_process: true,
        fields: [
          {:from, :instr_id, "instruction ID"},
          {:to, :instr_id, "next instruction ID (fallthrough)"}
        ],
        doc: "Sequential (fallthrough) instruction ordering."
      },
      %{
        name: :def,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:reg, :symbol, "defined register"}
        ],
        doc: "Register definition (write)."
      },
      %{
        name: :use,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:reg, :symbol, "used register"}
        ],
        doc: "Register use (read)."
      },
      %{
        name: :def_use,
        layer: 1,
        fields: [
          {:def_id, :symbol, "the instruction whose register write produces the value"},
          {:use_id, :symbol, "the instruction that reads it"}
        ],
        doc: """
        A write that can supply a read, accounting for register reuse and control flow. \
        Both columns are positional instruction IDs, so body edits invalidate these \
        rows. Use this relation only when value flow is needed.
        """
      },
      %{
        name: :literal_value,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:reg, :symbol, "destination register"},
          {:val, :symbol, "literal value (stringified)"}
        ],
        doc: "Literal value loaded into a register."
      },
      %{
        name: :tuple_literal,
        layer: 1,
        fields: [
          {:id, :symbol, "the constructing instruction"},
          {:reg, :symbol, "the destination x-register, e.g. 'x1'"},
          {:tag, :symbol, "the tuple's leading atom"},
          {:size, :number, "the tuple's arity"}
        ],
        doc: """
        A tuple constructed with a literal atom as its first element, with the \
        destination register. Complements `literal_value` for messages such as `{:get, \
        key}`. The register identifies the operand; `def_use` alone does not.
        """
      },
      %{
        name: :jump,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:target, :label, "target label number"}
        ],
        doc: "Unconditional jump to a label."
      },
      %{
        name: :branch,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:fail, :label, "the branch's label edge; falls through otherwise"},
          {:reserved, :number, "always 0 (kept for arity stability)"}
        ],
        doc:
          "Conditional two-way control transfer: the label edge plus fallthrough. " <>
            "For test instructions the label is the fail edge; for receive-loop " <>
            "control (loop_rec, wait_timeout) it is the empty-mailbox/loop-again edge."
      },
      %{
        name: :label_at,
        layer: 1,
        in_process: true,
        fields: [
          {:label, :label, "label number"},
          {:id, :instr_id, "instruction ID of the label"}
        ],
        doc: "Maps a label number to the instruction at that position."
      },
      %{
        name: :select_branch,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:val, :symbol, "matched value (stringified)"},
          {:target, :label, "target label number"}
        ],
        doc: "One arm of a select_val or select_tuple_arity."
      },
      %{
        name: :local_call,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:caller, :func_id, "containing function ID"},
          {:target, :symbol, "target label or MFA string"},
          {:arity, :number, "call arity"}
        ],
        doc: "Call to a local (same-module) function by label or MFA."
      },
      %{
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
      },
      %{
        name: :tail_call,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"}
        ],
        doc: "Marks an instruction as a tail call."
      },
      %{
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
      },
      %{
        name: :call_followed_by_branch,
        layer: 1,
        fields: [
          {:id, :instr_id, "call instruction ID"}
        ],
        doc: """
        A call with a `test` or `loop_rec` later in the same function. Computed by the \
        emitter to avoid joins on `instruction`. This is only a coarse proxy for \
        checking the call's result: the branch may belong to an unrelated clause.
        """
      },
      %{
        name: :conditional_call,
        layer: 1,
        fields: [
          {:id, :instr_id, "call instruction ID"}
        ],
        doc: """
        A call absent from at least one path that returns or tail-calls \
        (`Argus.Cfg.Function.completing_blocks/1`). Raising paths do not count. If no \
        path completes, uses control dependence on any branch instead.
        """
      },
      %{
        name: :site_block,
        layer: 1,
        fields: [
          {:id, :instr_id, "a call, receive or branch instruction"},
          {:kind, :symbol, "call | receive | branch"},
          {:block, :instr_id, "the first instruction of its basic block"},
          {:idx, :number, "its index in the function, which orders it within the block"}
        ],
        doc: """
        The basic block containing a named call, receive, or branch; blocks are \
        identified by their first instruction. Used with `block_flow` by \
        `clientlib/order.dl` to order calls and receives. BIFs, dynamic calls, and sends \
        have no rows. Branch rows are for in-process passes; a receive's `loop_rec` has \
        both kinds. Instruction IDs change on body edits.
        """
      },
      %{
        name: :block_flow,
        layer: 1,
        fields: [
          {:from, :instr_id, "a block holding a site_block row, by its first instruction"},
          {:to, :instr_id, "the next block holding one on a path from it"}
        ],
        doc: """
        Control-flow edges between `site_block` blocks, skipping intermediate blocks \
        without rows. Excludes loop back edges whose target dominates their source, \
        matching `Argus.Cfg.Function.precedes?/3`. The resulting closure orders sites \
        within one iteration; a receive's loop back to `loop_rec` adds no ordering.
        """
      },
      %{
        name: :send_msg,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:caller, :func_id, "containing function ID"}
        ],
        doc: "Message send instruction."
      },
      %{
        name: :recv_start,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:caller, :func_id, "containing function ID"},
          {:blocking, :number, "1 when the receive has no timeout and can block forever"},
          {:fail, :label, "failure label"}
        ],
        doc: """
        Start of a receive loop (`loop_rec`). The emitter follows its empty-mailbox \
        branch to classify the receive: `wait` can block indefinitely; `wait_timeout` \
        has a timeout.
        """
      },
      %{
        name: :spawn_call,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:caller, :func_id, "containing function ID"},
          {:mod, :symbol, "module of the function the new process runs, or \"dynamic\""},
          {:func, :symbol, "that function's name, or \"dynamic\""},
          {:arity, :number, "that function's arity, or -1"},
          {:variant, :symbol,
           "how the process is tied to the caller: spawn, spawn_link, spawn_monitor, start (proc_lib's unlinked start, which waits for the process's init_ack), or spawn_opt (options not literal)"},
          {:api, :symbol,
           "the spawning function, Mod.fun/n (:erlang.spawn/1, :proc_lib.start_link/3)"},
          {:source, :symbol,
           "how far the arguments resolve: closure, fun (a literal &Mod.f/n), param, mfa or dynamic"},
          {:param, :number,
           "the caller's parameter holding the fun when source is param, else -1"},
          {:args, :number,
           "the x register holding the argument list for the module-function forms, else -1"}
        ],
        doc: """
        A process spawn and its entry function, resolved by `Argus.Pipeline.Emit.Spawns` \
        from a closure, literal external fun, or module/function/argument list. Captured \
        variables count toward closure arity. A forwarded fun is `param`; unresolved \
        names are `dynamic` and unknown arity is -1. Known module or function names are \
        retained even if the other is unknown. `variant` comes from literal options. \
        `Argus.Extractors.PidFlow` uses the spawn site as the process identity.
        """
      },
      %{
        name: :fun_ref,
        layer: 1,
        fields: [
          {:caller, :func_id, "function holding the reference"},
          {:callee, :func_id, "function the fun value runs (mod:func/arity)"}
        ],
        doc: """
        A literal external fun passed to a call that may invoke it, with its argument \
        position (`Argus.Pipeline.Emit.FunRefs`). Excludes funs stored in terms, \
        returned by the callee, or also called directly. Local captures use \
        `closure_def` instead. The call graph follows this edge; same-process walks \
        consult `fun_handed` to exclude deferred or spawned execution.
        """
      },
      %{
        name: :fun_handed,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID of the call handed the fun"},
          {:caller, :func_id, "containing function ID"},
          {:callee, :func_id, "function the fun value runs (mod:func/arity)"},
          {:pos, :number, "0-based argument position the fun is handed in"}
        ],
        doc: """
        The call receiving a closure or literal external fun that runs `callee` \
        (`Argus.Pipeline.Emit.FunRefs`). Identifies the call site used to check `try` \
        coverage of the fun's execution. Excludes funs stored in terms or returned by \
        the receiving call.
        """
      },
      %{
        name: :resolved_apply,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID of the apply"},
          {:caller, :func_id, "containing function ID"},
          {:target, :func_id, "the MFA it actually calls"}
        ],
        doc: """
        An `apply` target resolved from reaching values (`Argus.Pipeline.Emit.Applies`), \
        including module/function registers, `erlang:apply/3`, and closure or \
        external-fun calls via `erlang:apply/2`. These calls enter the call graph and \
        use the target's effect classification instead of an opaque `dynamic_call` \
        effect.
        """
      },
      %{
        name: :try_start,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:caller, :func_id, "containing function ID"},
          {:kind, :symbol, "\"try\" or \"catch\" (the older syntax)"},
          {:handler, :label, "handler label"}
        ],
        doc: "Start of a try block."
      },
      %{
        name: :dynamic_call,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:caller, :func_id, "containing function ID"},
          {:kind, :symbol, "call_fun (a fun value) or apply (a computed MFA)"}
        ],
        doc: """
        A call through a fun value or computed module/function whose target is not \
        statically known. Unresolved calls limit reachability analysis and prevent \
        claims that require knowing every callee, such as proving a function pure.
        """
      },
      %{
        name: :closure_def,
        layer: 1,
        fields: [
          {:parent_func, :func_id, "function constructing the closure"},
          {:closure_func, :func_id, "function ID of the closure body"}
        ],
        doc: """
        A closure constructed by `parent_func` with target `closure_func`. Adds a \
        call-graph edge so reachability includes closure bodies. Emitted only for \
        concrete `{Mod, Func, Arity}` targets of `make_fun3`; raw-label targets are \
        omitted.
        """
      },
      %{
        name: :type_test,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:test, :symbol, "type test name (is_integer, is_atom, is_tuple, ...)"},
          {:src, :symbol, "register being type-tested"},
          {:fail, :label, "fail label if the test does not hold (0 = fallthrough)"}
        ],
        doc: """
        A compiler-emitted type test for a guard or pattern match, with the tested \
        register in `src`. Unlike `branch`, retains the test name for type narrowing on \
        the success edge. Extra operands of structural tests such as `is_tagged_tuple` \
        are omitted.
        """
      },
      %{
        name: :bs_start,
        layer: 1,
        in_process: true,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:fail, :label, "failure label"}
        ],
        doc: "Start of binary matching."
      },
      %{
        name: :line_info,
        layer: 1,
        fields: [
          {:id, :instr_id, "instruction ID"},
          {:line, :number, "source line number"}
        ],
        doc: """
        The source line active at an instruction, resolved from the BEAM Line chunk. \
        Each marker applies until the next. No row is emitted before the first marker, \
        under a no-location marker (reference 0), or without a parseable Line chunk.
        """
      },

      # Pipeline extraction failures. No Datalog rule reads these rows; `Argus.Findings`
      # reports them, and per-module consumers receive them with the module's facts.
      %{
        name: :extraction_error,
        layer: 1,
        fields: [
          {:mod, :symbol,
           "module whose extraction failed, as function_def spells it (the beam's path " <>
             "when not even its name could be read)"},
          {:step, :symbol,
           "the extractor that failed (its module name), or a pipeline stage: " <>
             "pipeline when the module as a whole did, or decode, cfg, reaching " <>
             "or conditional_call for what those stages provide"},
          {:reason, :symbol, "what went wrong, on one line"}
        ],
        doc: """
        An extraction failure for a module. A failed extractor or derived-facts stage \
        loses only its own rows. Failed disassembly, failed bytecode emission, or a \
        per-module timeout leaves only this error row. Analysis continues with the \
        available facts.
        """
      }
    ])
  end
end
