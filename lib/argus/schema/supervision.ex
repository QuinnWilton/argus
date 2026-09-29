defmodule Argus.Schema.Supervision do
  @moduledoc """
  Layer-2 supervision facts: supervisors, child specs, restart policies, and runtime \
  child starts. Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
      %{
        name: :supervisor,
        layer: 2,
        fields: [
          {:mod, :symbol, "supervisor module"},
          {:strategy, :symbol, "restart strategy"}
        ],
        doc: "Module that implements the Supervisor behaviour."
      },

      # Keep the finding anchor separate from `supervisor`: instruction IDs change on
      # body edits, while supervisor identity and strategy may not. Only analyses
      # needing the tree-definition location join this relation.
      %{
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
      },
      %{
        name: :supervisor_child,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:position, :number, "child start order"},
          {:child_mod, :symbol, "child module"},
          {:restart, :symbol,
           "restart the spec states (permanent/transient/temporary, permanent for a map " <>
             "with none), 'own' for a shorthand, whose module's child_spec/1 gives it, " <>
             "'dynamic' when the reader cannot tell"},
          {:type, :symbol, "child type (worker/supervisor)"}
        ],
        doc: """
        A supervisor child specification. Shorthand forms use restart `own`, resolved \
        from `child_spec_restart` or argument-dependent `child_spec_option`, unless \
        `Supervisor.child_spec/2` overrides it.
        """
      },
      %{
        name: :supervisor_children_open,
        layer: 2,
        fields: [{:sup, :symbol, "supervisor module"}],
        doc: """
        A child list with an unresolved element or tail. Its `supervisor_child` rows and \
        positions are partial; unseen children may start after any listed child. Fully \
        resolved lists retain source order (`Argus.Extractors.Supervision`).
        """
      },
      %{
        name: :supervisor_child_form,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:position, :number,
           "child start order — matches the paired supervisor_child.position"},
          {:form, :symbol, "'explicit' | 'shorthand'"}
        ],
        doc: """
        Whether a child type is explicit or an extractor default. Maps and OTP tuples \
        determine the type, including the map default `worker`. Shorthand forms defer to \
        `Module.child_spec/1`, so their provisional type must not be trusted without \
        this relation.
        """
      },
      %{
        name: :supervisor_child_name,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:position, :number,
           "child start order — matches the paired supervisor_child.position"},
          {:name, :symbol, "registered name from the child spec's :name option"}
        ],
        doc: """
        An atom registration name in a child spec's `:name` option, keyed by supervisor \
        and position. Resolves named `DynamicSupervisor.start_child` targets to the \
        registering child. Via and global names are excluded.
        """
      },
      %{
        name: :child_spec_restart,
        layer: 2,
        fields: [
          {:mod, :symbol, "module"},
          {:restart, :symbol,
           "restart its child_spec/1 states (permanent/transient/temporary, permanent " <>
             "for a spec that states none), 'dynamic' when the reader cannot read it"}
        ],
        doc: """
        A module's `child_spec/1` restart policy: the stated value, `permanent` for a \
        known map lacking `:restart`, or `dynamic` when unresolved. Argument-derived \
        values use `child_spec_option`. No row means no visible `child_spec/1`.
        """
      },
      %{
        name: :child_spec_option,
        layer: 2,
        fields: [
          {:mod, :symbol, "module"},
          {:field, :symbol, "the spec field it gives (restart, type)"},
          {:key, :symbol, "the option key it reads off child_spec/1's argument"},
          {:default, :symbol,
           "the value when the argument does not hold the key, 'dynamic' unread"}
        ],
        doc: """
        A child-spec field read from the function's argument, with its option key and \
        default. Shorthand starts resolve it through `shorthand_option`; a known options \
        argument lacking the key uses the default. Other arguments leave the value \
        unknown.
        """
      },
      %{
        name: :child_spec_type,
        layer: 2,
        fields: [
          {:mod, :symbol, "module"},
          {:type, :symbol, "type its child_spec/1 states (worker/supervisor)"}
        ],
        doc: """
        A module's `child_spec/1` type for shorthand starts: the stated type or `worker` \
        for a known map lacking it. Delegation to another module's `child_spec/1` has no \
        row.
        """
      },
      %{
        name: :post_start_call,
        layer: 2,
        fields: [
          {:func, :symbol, "function that started a supervisor"},
          {:site, :instr_id, "a call made after the Supervisor.start_link"},
          {:callee, :func_id, "what it calls (Mod:fun/arity)"}
        ],
        doc: "A call made after Supervisor.start_link returned, in the same function."
      },
      %{
        name: :dynamic_child,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor module (or 'dynamic' if not statically resolvable)"},
          {:child_mod, :symbol, "child module being started"},
          {:caller_func, :symbol, "function that calls start_child"}
        ],
        doc: """
        A runtime child added by `DynamicSupervisor.start_child/2`. Makes dynamic \
        workers visible alongside static supervision children.
        """
      },
      %{
        name: :shorthand_arg,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor, as the start's own row names it"},
          {:child_mod, :symbol, "child module"},
          {:at, :symbol,
           "the start: its position in the child list, or the function that calls start_child"},
          {:shape, :symbol,
           "'options' when the argument is options every key of which is known, else 'dynamic'"}
        ],
        doc: """
        A shorthand child start and its argument shape. Covers static, dynamic, and \
        added children. `options` means a fully known keyword list or atom-keyed map, \
        with entries in `shorthand_option`; other arguments use `dynamic`. Bare modules \
        use `[]`.
        """
      },
      %{
        name: :shorthand_option,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor, as shorthand_arg's"},
          {:child_mod, :symbol, "child module, as shorthand_arg's"},
          {:at, :symbol, "the start, as shorthand_arg's"},
          {:key, :symbol, "an option key the argument holds"},
          {:value, :symbol, "its value: an atom or an integer, 'dynamic' unread"}
        ],
        doc: "An option a shorthand start's `options` argument holds (`shorthand_arg`)."
      },
      %{
        name: :dynamic_child_restart,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor module (or 'dynamic'), as dynamic_child's"},
          {:child_mod, :symbol, "child module, as dynamic_child's"},
          {:caller_func, :symbol, "function that calls start_child, as dynamic_child's"},
          {:restart, :symbol,
           "restart the start_child's own spec states (permanent/transient/temporary, " <>
             "permanent for a map with none), 'dynamic' when the spec's restart could not be read"}
        ],
        doc: """
        The restart policy stated by a dynamic child's explicit spec or \
        `Supervisor.child_spec/2` override. Known maps without `:restart` use \
        `permanent`. Shorthand forms have no row here; `dynamic_restart` in \
        `clientlib/supervision.dl` also resolves their module-defined policy.
        """
      },
      %{
        name: :added_child,
        layer: 2,
        fields: [
          {:sup, :symbol,
           "supervisor the child is added to (or 'dynamic' if not statically resolvable)"},
          {:child_mod, :symbol, "child module"},
          {:restart, :symbol,
           "restart the spec states or defaults to (permanent/transient/temporary), " <>
             "'own' for a shorthand, whose module's child_spec/1 gives it, " <>
             "'dynamic' when the reader cannot tell"},
          {:type, :symbol, "child type the spec states or defaults to (worker/supervisor)"},
          {:caller_func, :symbol, "function that calls start_child"}
        ],
        doc: """
        A child added by `Supervisor.start_child/2` or `:supervisor.start_child/2`, with \
        spec, restart, and type. Excludes DynamicSupervisor children, simple_one_for_one \
        argument lists, and unresolved specs.
        """
      },
      %{
        name: :task_supervisor_start,
        layer: 2,
        fields: [
          {:id, :instr_id, "the call"},
          {:func, :func_id, "the function making it"},
          {:op, :symbol, "start_child, async, async_nolink, async_stream or async_stream_nolink"},
          {:sup, :symbol,
           "the Task.Supervisor the call names: its registered name, a " <>
             "PartitionSupervisor's name for a {:via, PartitionSupervisor, {name, key}}, " <>
             "or 'dynamic' (a pid, a {name, node}, a name the reader cannot read)"}
        ],
        doc: """
        A Task.Supervisor task start and its API, supplementing `dynamic_child`. Stream \
        APIs run up to `max_concurrency` tasks per enumerating process; other APIs start \
        one task per call. Supervisor names join `task_supervisor_cap`.
        """
      },
      %{
        name: :task_supervisor_cap,
        layer: 2,
        fields: [
          {:sup, :symbol,
           "the name it is registered under (a PartitionSupervisor's for its " <>
             "partitions), or 'dynamic' when the options state none the reader reads"},
          {:limit, :symbol,
           "its max_children: the literal cap, 'infinity' when the options state " <>
             "none or :infinity, 'dynamic' when the options or the cap cannot be read"}
        ],
        doc: """
        A Task.Supervisor start and its cap, from child specs, PartitionSupervisor \
        options, or direct start/child-spec calls. Records capped and uncapped starts. A \
        cap can produce `{:error, :max_children}`; an unavailable supervisor instead \
        exits the caller. No row means the start is not visible.
        """
      },
      %{
        name: :supervisor_max_children,
        layer: 2,
        fields: [
          {:sup, :symbol, "the DynamicSupervisor module"},
          {:limit, :symbol, "the configured cap, 'dynamic' when the options may set one"}
        ],
        doc: """
        A DynamicSupervisor `max_children` cap. A finite value is recorded directly; \
        incomplete options use `dynamic`. Fully known options without a cap have no row, \
        reflecting the default `:infinity`.
        """
      },
      %{
        name: :socket_transport,
        layer: 2,
        fields: [
          {:endpoint, :symbol, "the Phoenix endpoint module"},
          {:path, :symbol, "the socket's mount path"},
          {:transport, :symbol, "'websocket' | 'longpoll'"}
        ],
        doc: """
        An enabled socket transport from an endpoint's compiled `__sockets__/0`. Records \
        only present, non-false transports, matching Phoenix.
        """
      }
    ])
  end
end
