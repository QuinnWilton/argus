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

  @type field_type :: :symbol | :number
  @type field :: {atom(), field_type(), String.t()}

  @type relation :: %{
          name: atom(),
          layer: 1 | 2,
          fields: [field()],
          doc: String.t()
        }

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
      {:func, :symbol, "function ID (mod:name/arity)"},
      {:mod, :symbol, "module name"},
      {:name, :symbol, "function name"},
      {:arity, :number, "function arity"},
      {:entry, :number, "entry label number"},
      {:exported, :number, "1 if exported, 0 if local"}
    ],
    doc: "Function definition within a module."
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
      {:id, :symbol, "unique instruction ID"},
      {:func, :symbol, "containing function ID"},
      {:idx, :number, "instruction index within function"},
      {:op, :symbol, "opcode name"}
    ],
    doc: "Every instruction in every function."
  }

  @next %{
    name: :next,
    layer: 1,
    fields: [
      {:from, :symbol, "instruction ID"},
      {:to, :symbol, "next instruction ID (fallthrough)"}
    ],
    doc: "Sequential (fallthrough) instruction ordering."
  }

  # Layer 1: Register / data flow facts.

  @move %{
    name: :move,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:src, :symbol, "source operand"},
      {:dst, :symbol, "destination operand"}
    ],
    doc: "Data move from source to destination."
  }

  @def_rel %{
    name: :def,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:reg, :symbol, "defined register"}
    ],
    doc: "Register definition (write)."
  }

  @use_rel %{
    name: :use,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:reg, :symbol, "used register"}
    ],
    doc: "Register use (read)."
  }

  @literal_value %{
    name: :literal_value,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
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
      {:id, :symbol, "instruction ID"},
      {:target, :number, "target label number"}
    ],
    doc: "Unconditional jump to a label."
  }

  @branch %{
    name: :branch,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:on_true, :number, "label if condition holds"},
      {:on_false, :number, "label if condition fails (0 = fallthrough)"}
    ],
    doc: "Conditional branch (test instructions)."
  }

  @label_at %{
    name: :label_at,
    layer: 1,
    fields: [
      {:label, :number, "label number"},
      {:id, :symbol, "instruction ID of the label"}
    ],
    doc: "Maps a label number to the instruction at that position."
  }

  @select_branch %{
    name: :select_branch,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:val, :symbol, "matched value (stringified)"},
      {:target, :number, "target label number"}
    ],
    doc: "One arm of a select_val or select_tuple_arity."
  }

  # Layer 1: Call facts.

  @local_call %{
    name: :local_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:target, :symbol, "target label or MFA string"},
      {:arity, :number, "call arity"}
    ],
    doc: "Call to a local (same-module) function by label or MFA."
  }

  @remote_call %{
    name: :remote_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
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
      {:id, :symbol, "instruction ID"}
    ],
    doc: "Marks an instruction as a tail call."
  }

  @bif_call %{
    name: :bif_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:mod, :symbol, "BIF module"},
      {:func, :symbol, "BIF function"},
      {:arity, :number, "BIF arity"},
      {:fail, :number, "failure label (0 = no fail)"}
    ],
    doc: "Built-in function call."
  }

  # Layer 1: BEAM-specific facts.

  @allocate %{
    name: :allocate,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:stack, :number, "stack words allocated"},
      {:live, :number, "live X registers"}
    ],
    doc: "Stack frame allocation."
  }

  @deallocate %{
    name: :deallocate,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:stack, :number, "stack words deallocated"}
    ],
    doc: "Stack frame deallocation."
  }

  @send_msg %{
    name: :send_msg,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "Message send instruction."
  }

  @recv_start %{
    name: :recv_start,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:fail, :number, "failure label"}
    ],
    doc: "Start of a receive loop (loop_rec)."
  }

  @recv_end %{
    name: :recv_end,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "End of a receive clause (remove_message)."
  }

  @spawn_call %{
    name: :spawn_call,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
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
      {:id, :symbol, "instruction ID"},
      {:handler, :number, "handler label"}
    ],
    doc: "Start of a try block."
  }

  @try_end %{
    name: :try_end,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"}
    ],
    doc: "End of a try block."
  }

  @make_fun %{
    name: :make_fun,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:target, :number, "lambda body label"},
      {:num_free, :number, "number of captured variables"}
    ],
    doc: "Lambda/closure creation."
  }

  @closure_def %{
    name: :closure_def,
    layer: 1,
    fields: [
      {:parent_func, :symbol, "function constructing the closure"},
      {:closure_func, :symbol, "function ID of the closure body"}
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
      {:id, :symbol, "instruction ID"},
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
      {:id, :symbol, "instruction ID"},
      {:test, :symbol, "type test name (is_integer, is_atom, is_tuple, ...)"},
      {:src, :symbol, "register being type-tested"},
      {:fail, :number, "fail label if the test does not hold (0 = fallthrough)"}
    ],
    doc: """
    Unary type-test instructions emitted by the compiler for guard \
    narrowing. Captures the test name (which the generic `branch` fact \
    discards) so type-narrowing dataflow analyses can reason about which \
    register has which inferred type on the success edge.
    """
  }

  @unhandled_op %{
    name: :unhandled_op,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
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
      {:id, :symbol, "instruction ID"},
      {:fail, :number, "failure label"}
    ],
    doc: "Start of binary matching."
  }

  @line_info %{
    name: :line_info,
    layer: 1,
    fields: [
      {:id, :symbol, "instruction ID"},
      {:line, :number, "source line number"}
    ],
    doc: "Source line number annotation."
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
      {:name, :symbol, "global name"}
    ],
    doc: ":global.register_name call."
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
      {:state, :symbol, "state atom"}
    ],
    doc: "State in a gen_statem state machine."
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

  # All relations indexed by name.

  @layer_1_relations [
    @module_info,
    @function_def,
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
    @allocate,
    @deallocate,
    @send_msg,
    @recv_start,
    @recv_end,
    @spawn_call,
    @try_start,
    @try_end,
    @make_fun,
    @closure_def,
    @tuple_field_access,
    @type_test,
    @unhandled_op,
    @bs_start,
    @line_info
  ]

  @layer_2_relations [
    @supervisor,
    @supervisor_child,
    @dynamic_child,
    @named_process,
    @process_link,
    @implements_behaviour,
    @sync_call,
    @async_cast,
    @sync_call_timeout,
    @sync_call_via,
    @delayed_message,
    @gen_event_handler,
    @ets_new,
    @ets_option,
    @ets_op,
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
    @statem_transition,
    @statem_timeout
  ]

  @all_relations @layer_1_relations ++ @layer_2_relations

  @relations_by_name Map.new(@all_relations, fn r -> {r.name, r} end)

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
  """
  @spec souffle_decl(atom()) :: String.t()
  def souffle_decl(name) do
    rel = fetch!(name)

    fields_str =
      rel.fields
      |> Enum.map(fn {fname, ftype, _doc} -> "#{fname}: #{ftype}" end)
      |> Enum.join(", ")

    ".decl #{name}(#{fields_str})"
  end

  @doc """
  Returns all relation names.
  """
  @spec names() :: [atom()]
  def names, do: Enum.map(@all_relations, & &1.name)
end
