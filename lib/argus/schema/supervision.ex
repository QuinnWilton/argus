defmodule Argus.Schema.Supervision do
  @moduledoc """
  Supervision trees: the supervisors a module defines, their children
  and how each is written, how they restart, and what runs after they
  start.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
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

      # The tree-definition site is where a FINDING should be anchored, not
      # something the logic joins on — so it lives apart from `supervisor`. It
      # is an instruction ID, which renumbers whenever anything earlier in the
      # supervisor's init shifts; keeping it in `supervisor` made every rule
      # that merely asks "is this module a supervisor, and with what strategy"
      # churn on unrelated edits. Analyses that anchor a finding at the tree
      # definition join this relation explicitly and accept that coupling.
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
          {:restart, :symbol, "restart type (permanent/transient/temporary)"},
          {:type, :symbol, "child type (worker/supervisor)"}
        ],
        doc: "Child specification within a supervisor."
      },
      %{
        name: :supervisor_children_open,
        layer: 2,
        fields: [{:sup, :symbol, "supervisor module"}],
        doc: """
        The supervisor's child list has an element or a tail the extractor \
        cannot read: a list appended from config, an `Enum.map`, a \
        parameter, a spec from a call it does not follow \
        (`Supervisor.child_spec/2` it does). Its `supervisor_child` rows \
        are partial, and their positions too: a child the list does not \
        show may start after any it lists. A list read to its end is \
        closed, and its rows are in source order \
        (`Argus.Extractors.Supervision`).
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
        Whether a child spec stated its `type`, or whether \
        `supervisor_child.type` is the extractor's default.

        A map spec and OTP's tuple form are the program's statement: a map \
        with no `:type` is a worker by the supervisor's own default (round \
        4 of the mining: supavisor 6b77121 registered a supervisor so). \
        The `{Module, args}` and bare-`Module` forms state nothing: \
        `Module.child_spec/1` decides, and `use Supervisor` generates \
        `type: :supervisor` where the default written here is `worker`. Any \
        rule reading `type` must join this, or it is reasoning about a guess — \
        a first attempt at "supervisor registered as a worker" reported 26 \
        modules on the corpus and every one was this artefact.
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
        Registered name declared in a child spec's `:name` option — e.g. \
        the `MyApp.Pool` in `{DynamicSupervisor, name: MyApp.Pool}`. Recorded \
        alongside `supervisor_child` (same `sup`/`position`) so a \
        `dynamic_child` whose parent is a registered name can be anchored to \
        the child that registers it: a `DynamicSupervisor.start_child(MyApp.Pool, _)` \
        call resolves to the named child instead of appearing unanchored. \
        Only atom names are recorded — `{:via, _, _}` and `{:global, _}` names \
        are not, since name-based `start_child` targets are always atoms.
        """
      },
      %{
        name: :child_spec_restart,
        layer: 2,
        fields: [
          {:mod, :symbol, "module"},
          {:restart, :symbol, "restart its child_spec/1 declares (permanent/transient/temporary)"}
        ],
        doc: "The restart type a module's own child_spec/1 gives a shorthand {Mod, args} spec."
      },
      %{
        name: :child_spec_type,
        layer: 2,
        fields: [
          {:mod, :symbol, "module"},
          {:type, :symbol, "type its child_spec/1 states (worker/supervisor)"}
        ],
        doc: """
        The type a module's own child_spec/1 gives the child a shorthand \
        `{Mod, args}`, a bare `Mod` or a `start_child` of one names: a \
        spec's `:type`, or `worker` for a map it writes with none (the \
        supervisor's default). `use Supervisor` states `supervisor`; a \
        child_spec/1 that hands back another module's states nothing, and \
        no row is written.
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
        Runtime-spawned child via `DynamicSupervisor.start_child/2`. Captured \
        so analyses like `one_for_one_coupling` can see workers added at \
        runtime (connection pools, per-tenant supervisors, plugin systems) \
        that wouldn't appear in any static `init/1` child spec scan.
        """
      },
      %{
        name: :dynamic_child_restart,
        layer: 2,
        fields: [
          {:sup, :symbol, "supervisor module (or 'dynamic'), as dynamic_child's"},
          {:child_mod, :symbol, "child module, as dynamic_child's"},
          {:caller_func, :symbol, "function that calls start_child, as dynamic_child's"},
          {:restart, :symbol,
           "restart the start_child's own spec states (permanent/transient/temporary), " <>
             "'dynamic' when the spec's restart could not be read"}
        ],
        doc: """
        The restart a `DynamicSupervisor.start_child/2`'s own spec states \
        for the child its `dynamic_child` row names: a map's `:restart`, \
        `:permanent` for a map with none (the map does not call the \
        module's child_spec/1, so `use GenServer, restart: :temporary` does \
        not apply), or `Supervisor.child_spec/2`'s overrides (redix \
        e67e61a: `Supervisor.child_spec({Redix, opts}, restart: \
        :temporary)`). No row for a shorthand, whose restart its own \
        child_spec/1 gives (`child_spec_restart`); \
        `clientlib/supervision.dl`'s `dynamic_restart` reads both.
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
             "'dynamic' when the reader cannot tell"},
          {:type, :symbol, "child type the spec states or defaults to (worker/supervisor)"},
          {:caller_func, :symbol, "function that calls start_child"}
        ],
        doc: """
        A child a `Supervisor.start_child/2` or `supervisor:start_child/2` \
        call adds to a supervisor, beside the children its init/1 lists: \
        `supervisor:start_child(kernel_safe_sup, {dets, {dets_server, \
        start_link, []}, permanent, ...})`. The spec is read as an element \
        of a child list is, with its restart and type. Not a \
        DynamicSupervisor's child (`dynamic_child`), of which a program \
        starts many, and not a simple_one_for_one template's (the argument \
        is a list of arguments, and the supervisor's init/1 names the \
        child); a spec the extractor cannot read names no child.
        """
      },
      %{
        name: :task_supervisor_start,
        layer: 2,
        fields: [
          {:id, :instr_id, "the call"},
          {:func, :func_id, "the function making it"},
          {:op, :symbol, "start_child, async, async_nolink, async_stream or async_stream_nolink"}
        ],
        doc: """
        A task started under a Task.Supervisor, beside its `dynamic_child` \
        row (child `Task`), which does not say how: `async_stream` and \
        `async_stream_nolink` run at most `max_concurrency` tasks at a time \
        for the process enumerating the stream, the others start one each.
        """
      },
      %{
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
        A socket transport an endpoint enables, read from the literal that \
        `socket/3` compiles into `__sockets__/0`. Emitted only for transports \
        that are present and not `false`, which is how Phoenix reads them.
        """
      }
    ])
  end
end
