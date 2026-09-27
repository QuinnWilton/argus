defmodule Argus.Schema.Bytecode do
  @moduledoc """
  The generic bytecode facts every module yields, whatever it does: its
  functions, their instructions, how values and control move between
  them, the calls, and the BEAM operations the analyses name (a send, a
  receive, a spawn, a try). The emitter writes them
  (`Argus.Pipeline.Emit`); the relations marked `in_process` exist for
  the passes that run in the VM and reach no Souffle program.

  Layer 1 of `Argus.Schema`, which reads the relations from here.
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

      # The entry label lives apart from function_def on purpose. It is a label
      # NUMBER, so it shifts whenever anything earlier in the module changes —
      # which made every row of function_def churn on any edit, even though no
      # Datalog rule has ever bound the column (all 55 uses wildcard it). Only
      # `Argus.Cfg` needs it, to root the control-flow graph. Splitting it out
      # keeps function_def stable under body edits, so a consumer memoizing per
      # relation can tell that editing one function cannot have changed a
      # conclusion drawn from another's signature. Same reasoning as keeping
      # line_info out of the semantic fact set.
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
        A reaching definition: this write can produce the value that read \
        consumes. True def→use, respecting register reuse and control flow, \
        rather than register-name matching — the difference between knowing \
        where a value came from and guessing.

        Volatile by construction. Both columns are positional instruction IDs, \
        so editing a function body churns every edge in it. Only analyses that \
        genuinely need value flow should declare it; the rest keep the \
        incrementality that removing `instruction` from every rule bought.
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
        A tuple built with a literal atom head. Complements `literal_value`, \
        which already records scalars written by `move` — including atoms — \
        with their register; `put_tuple2` was the gap, so `{:get, key}` was \
        invisible where a bare `:get` was not, and those are different messages.

        The register is the point. `def_use` says which write feeds which read \
        but not which OPERAND, so a call reading {x,0} and {x,1} gets two edges \
        and neither says which is the message. The write knows.
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
      },
      %{
        name: :conditional_call,
        layer: 1,
        fields: [
          {:id, :instr_id, "call instruction ID"}
        ],
        doc: """
        A call instruction (local, remote, or BIF) that does not execute on \
        every path through its function that completes (returns or tail \
        calls): its block is not on every such path \
        (`Argus.Cfg.Function.completing_blocks/1`). A path that raises is \
        none of them, so a clause head failing into `func_info` or a \
        badmatch is no branch. Derived per module from the control-flow \
        graph, so an analysis can tell "init/1 calls X" from "init/1 calls \
        X when an option is set" without reading `instruction` or \
        reconstructing control flow in Datalog. A function no path of which \
        completes falls back to control dependence on any branch.
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
        The basic block (`Argus.Cfg`) holding each instruction a rule asks \
        the order of: a call to a named function (`local_call`, \
        `remote_call`), a receive (`recv_start`) and a branch (`branch`, \
        which only the in-process passes read: `kind` says which a row is, \
        and a receive's `loop_rec` is both). A block is named by its first \
        instruction. With `block_flow` it is what clientlib/order.dl's \
        `runs_after` reads, so a rule asks whether one instruction runs \
        after another without reading `instruction` or `next`, the largest \
        and most volatile relations in the schema. `runs_after` is asked of \
        a call or a receive, so only the instructions such an order takes \
        part in have a row: one a call or receive runs before, and a call \
        or receive something runs after. A BIF instruction, a call through \
        a fun or `apply`, and a send have none. Positional like `def_use`: \
        an edit to a function body moves its rows.
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
        Control passes from one `site_block` block to another within one \
        trip through their function, through blocks holding no row: \
        `Argus.Cfg`'s edges less one into a block that dominates its \
        source (a loop's back edge), as `Argus.Cfg.Function.precedes?/3` \
        reads the graph, contracted to the blocks holding a `site_block` \
        row. An edge joins a block to each such block that is the next on \
        a path from it, so the closure is the graph's, restricted to those \
        blocks. A receive's loop back to its `loop_rec` is no flow, so one \
        trip through a receive orders its clauses after it and nothing \
        before it.
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
        Start of a receive loop (loop_rec).

        `blocking` distinguishes the two shapes a receive compiles to. The \
        loop_rec's fail label leads to the empty-mailbox block, which ends in \
        either `wait` (re-enter the loop and sleep — no timeout, so the process \
        can block forever) or `wait_timeout` (bounded). That distinction is only \
        visible by following a label to another instruction, so it is resolved \
        in the emitter and recorded here rather than left for a rule to \
        reconstruct.
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
        A call that starts a process running a function its arguments name — `erlang:spawn/1..4`, `spawn_link`, `spawn_monitor` and `spawn_opt/2..5`, `proc_lib:spawn*`, `start`, `start_link` and `start_monitor`, `Process.spawn/2,4` — and what that function is (`Argus.Pipeline.Emit.Spawns`): the function a closure was lifted to (`-f/1-fun-0-`, its arity counting the captured variables), the one a literal external fun names, or M.F/length(args) when M and F are literal (the arity -1 when the list's length is not). A fun that is the caller's parameter is `param`, for the rules to look up at the callers. What does not resolve is "dynamic" and -1; a literal M or F is kept beside an unknown other. `variant` reads a literal options list. A spawn is a process allocation site: `Argus.Extractors.PidFlow` names the processes it creates by it.
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
        A function hands `callee`, as a fun value, to a call that may invoke it, and does not call it itself (`Argus.Pipeline.Emit.FunRefs`): a literal external fun `&Mod.f/1`, or `erlang:make_fun/3` of literals, in argument position `pos`, whose data the call's result does not carry. `Enum.map(list, &URI.parse/1)` names `URI.parse/1` only here; `Keyword.get(opts, :on_fail, &M.f/2)` hands the fun back to be stored, and a fun built into a tuple, list or map, or held in a literal table, is not handed to a call. The call graph follows it like `closure_def`; the same-process walks set it aside where the call it is handed to starts a process on it or keeps it to run later (`fun_handed`, clientlib/runs_elsewhere.dl), as they do a closure. A local capture (`&helper/1`) is a `make_fun3`, and so a `closure_def`. A function that also calls `callee` directly has no row: the call relations already give that edge.
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
        The call at `id` is handed, as a fun value, a function that runs `callee` (`Argus.Pipeline.Emit.FunRefs`): a closure the caller builds (`make_fun3`, a `closure_def`) or a literal external fun (a `fun_ref`), in an argument position whose data the call's result does not carry. The call graph's edge into a closure or a fun reference has no call instruction of its own; this is the call it runs inside, so a rule that asks whether a `try` covers the edge asks it of this call (`Enum.each(peers, fn p -> ... end)` runs the closure inside `Enum.each`). A fun stored, built into a term, or handed back by the call has no row.
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
        An apply whose target the values reaching it name     (`Argus.Pipeline.Emit.Applies`): the `apply` instruction's module and     function registers, `erlang:apply/3`'s module and function with the     argument list's length, `erlang:apply/2`'s closure or literal external     fun. The compiler turns an apply it can read whole into a direct call,     so these are the ones it could not fold: a module or function that     arrives through a variable it did not track.

        A resolved apply is a call: the call graph follows it, and the effect     model classifies its target rather than reporting the `dynamic_call`     opaque.
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
      },
      %{
        name: :closure_def,
        layer: 1,
        fields: [
          {:parent_func, :func_id, "function constructing the closure"},
          {:closure_func, :func_id, "function ID of the closure body"}
        ],
        doc: """
        Closure construction edge: `parent_func` builds a closure pointing at \
        `closure_func`. Treated as a static call edge in the call graph so that \
        reachability over `call_edge` follows execution into closure bodies passed to \
        higher-order callees (`Enum.map`, `:telemetry.span`, `Task.async`, etc.).

        Only emitted when the `make_fun3` target is a concrete `{Mod, Func, Arity}` \
        triple. Closures targeting raw labels (rare in modern BEAM) are skipped \
        because we don't have the closure's function ID at emit time.
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
        Type-test instructions emitted by the compiler for guard and \
        pattern-match narrowing (`is_integer`, `is_tuple`, and the structural \
        `is_nonempty_list`/`is_tagged_tuple`, whose extra operands are not \
        recorded — `src` is always the tested register). Captures the test \
        name (which the generic `branch` fact discards) so type-narrowing \
        dataflow analyses can reason about which register has which inferred \
        type on the success edge.
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
        The source line in effect at this instruction: line markers are \
        resolved through the Line chunk at emit time and stamped onto every \
        following instruction until the next marker, so any instruction ID \
        an anchor names resolves to its exact line. Instructions with no \
        line in effect — before the first marker, under a no-location marker \
        (reference 0, on compiler-generated code), or in modules without a \
        parseable Line chunk — emit no rows.
        """
      },

      # Written by the pipeline, not by an extractor: what extraction could not
      # do. Read by no rule; `Argus.Findings` reports it, and a consumer that
      # extracts per module (scry) finds the rows in the module's facts.
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
        An extraction step that failed on a module. An extractor or a \
        derived-facts stage that raises costs only its own rows for that \
        module: the bytecode facts and every other step's rows stand. A \
        module whose disassembly or bytecode facts raise, or whose extraction \
        outlives the pipeline's per-module timeout, contributes this row and \
        nothing else. Either way the run goes on, and the analyses answer for \
        what was extracted.
        """
      }
    ])
  end
end
