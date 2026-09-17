defmodule Argus.Analyses.SyncCallInInit do
  @moduledoc """
  Synchronous calls in init/1 detection.

  Identifies GenServer/Supervisor modules whose `init/1` callback makes
  synchronous calls (directly or transitively through the call graph). When
  combined with supervision ordering, detects guaranteed deadlocks: a child's
  init blocks on a sibling that hasn't started yet.

  Supervision-aware filtering removes proven-safe findings:

  - **Safe sibling**: the callee starts earlier under the same supervisor,
    so it is already running when the caller's `init/1` executes.
  - **Safe cross-supervisor**: the caller and callee are under disjoint
    supervisor trees, so the callee was started by a different supervisor
    and is already running.

  Requires the OTP and Supervision extractors for `sync_call`,
  `implements_behaviour`, `supervisor`, and `supervisor_child` facts.

  ## Output relations

  - `sync_call_in_init(mod, callee_mod)` — module whose init/1 sync-calls callee_mod (after filtering proven-safe cases).
  - `init_deadlock_risk(sup, child, dep, child_pos, dep_pos)` — child's init calls a later-starting sibling.
  - `sup_call_in_init(mod, api, op, target, site)` — init/1 reaches a
    supervisor management call (`start_child`, `terminate_child`, ...).
  - `init_waits_on_blocking_server(mod, dep, handler, op_site)` — a call
    from init/1 that the tree-order argument accepts, into a server whose
    handler itself blocks on a supervisor op or a GenServer.call.

  ## Finding severities

  - `sync_call_in_init` — `:info`. The target's liveness couldn't be
    proven either way; the call stalls startup whenever the target is
    slow or absent.
  - `init_deadlock_risk` — `:error`. Supervisors start children in order
    and `init/1` blocks that sequence, so an init that waits on a
    later-starting sibling is a deadlock by construction.
  - `sup_call_in_init` — `:info`. Starting children from init/1 puts
    their inits on the startup path; whether one calls back is not known
    here.
  - `init_waits_on_blocking_server` — `:warning`. The callee is running,
    but a handler of its blocks on something with no bound: a
    `terminate_child`/`stop`, or a GenServer.call with `:infinity`.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :sync_call_in_init

  @impl true
  def description, do: "synchronous calls in init/1 (startup deadlock) detection"

  @impl true
  def rules_file, do: "analyses/sync_call_in_init.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.Supervision,
      Argus.Extractors.CallbackTag,
      # sync_call_in_init's rules reach `sync_call` through
      # clientlib/interprocedural.dl, which resolves a target module
      # forwarded through a wrapper — `defp fetch(server), do:
      # GenServer.call(server, ...)` called from init with a literal.
      # Nothing declared CallArgs, so call_arg and call_arg_forward were
      # empty and that resolution never ran.
      Argus.Extractors.CallArgs
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :blocking_recv_in_init,
        fields: [
          {:mod, :symbol, "module whose init/1 reaches the receive"},
          {:recv, :symbol, "the function receiving with no timeout"}
        ],
        doc: "init/1 reaches a socket receive with an :infinity timeout."
      },
      %{
        name: :sync_call_in_init,
        fields: [
          {:mod, :symbol, "module whose init/1 makes a sync call"},
          {:callee, :symbol, "target module of the sync call"},
          {:kind, :symbol,
           "unconditional, or conditional when every path is branch-guarded in init"}
        ],
        doc: "Module whose init/1 transitively makes a synchronous call."
      },
      %{
        name: :sup_call_in_init,
        fields: [
          {:mod, :symbol, "module whose init/1 reaches the call"},
          {:api, :symbol,
           "Supervisor, DynamicSupervisor, Task.Supervisor or PartitionSupervisor"},
          {:op, :symbol, "start_child, terminate_child, which_children, ..."},
          {:target, :symbol, "the supervisor argument, or 'dynamic'"},
          {:site, :symbol, "the call site"}
        ],
        key: [:mod, :api, :op],
        doc: "init/1 makes a synchronous supervisor management call."
      },
      %{
        name: :init_waits_on_blocking_server,
        fields: [
          {:mod, :symbol, "module whose init/1 calls dep"},
          {:dep, :symbol, "the server called"},
          {:handler, :symbol, "a handler of dep that blocks"},
          {:op_site, :symbol, "the blocking call inside that handler"}
        ],
        key: [:mod, :dep],
        doc:
          "init/1 calls a running server whose handler blocks on a supervisor op or a GenServer.call."
      },
      %{
        name: :init_deadlock_risk,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:child, :symbol, "child module whose init calls dep"},
          {:dep, :symbol, "dependency module (starts later)"},
          {:child_pos, :number, "child start position"},
          {:dep_pos, :number, "dependency start position"}
        ],
        doc: "Child's init sync-calls a sibling that starts later."
      }
    ]
  end

  @impl true
  def finding(:blocking_recv_in_init, [mod, recv]) do
    Findings.new(
      :warning,
      "init/1 waits on a socket with no timeout",
      "#{mod}'s init/1 reaches #{recv}, which waits on a socket with :infinity " <>
        "(or a `receive` with no `after`). Until the message arrives, the process is not started: its " <>
        "supervisor's start, and whoever called start_child, wait with it — " <>
        "for as long as the server stays silent.",
      at: Findings.at_func(recv),
      at_label: "receives with :infinity",
      help: [
        "bound the receive (a connect timeout) and fail the start with an error",
        "or connect after init returns (`{:continue, :connect}`) so the start completes"
      ]
    )
  end

  def finding(:sync_call_in_init, [mod, callee, "conditional"]) do
    Findings.new(
      :info,
      "init/1 can block on a synchronous call",
      "#{mod}.init/1 makes a synchronous call to #{callee} on some paths " <>
        "only: every route from init to the call passes through a branch in " <>
        "init (an option such as `sync_connect: true`, a case on the " <>
        "argument). When that path is taken the tree's startup stalls for " <>
        "as long as #{callee} takes to answer; a proven startup deadlock is " <>
        "reported separately as an error.",
      at: Findings.at_mfa(mod, :init, 1),
      at_label: "this init can block the start sequence",
      help: [
        "if the blocking path is an opt-in, document that it blocks " <>
          "startup; otherwise defer the call to `handle_continue/2`"
      ],
      related: [Findings.related("call target", Findings.at_module(callee))]
    )
  end

  def finding(:sync_call_in_init, [mod, callee, "unconditional"]) do
    Findings.new(
      :info,
      "init/1 blocks on a synchronous call",
      "#{mod}.init/1 makes a synchronous call to #{callee} (directly or " <>
        "transitively) on every init. init runs inside the supervisor's " <>
        "start sequence, so the tree's startup stalls for as long as " <>
        "#{callee} takes to answer. Argus could not establish where " <>
        "#{callee} runs relative to this init — its child spec is built at " <>
        "runtime — so this is a note, not a diagnosis; a proven startup " <>
        "deadlock is reported separately as an error.",
      at: Findings.at_mfa(mod, :init, 1),
      at_label: "this init blocks the start sequence",
      help: [
        "defer the call to `handle_continue/2`: return " <>
          "`{:ok, state, {:continue, :finish_init}}` from init and make the " <>
          "call in `handle_continue(:finish_init, state)`"
      ],
      related: [Findings.related("call target", Findings.at_module(callee))]
    )
  end

  def finding(:sup_call_in_init, [mod, api, op, target, site]) do
    target_text =
      case target do
        "dynamic" -> "a supervisor chosen at runtime"
        "via:" <> registry -> "a supervisor named through #{registry}"
        other -> other
      end

    Findings.new(
      :info,
      "init/1 makes a synchronous supervisor call",
      "#{mod}.init/1 reaches #{api}.#{op} on #{target_text}. Every " <>
        "supervisor management call is a GenServer.call into the " <>
        "supervisor; start_child in particular does not return until the " <>
        "new child's init/1 has, so those inits now run inside this one, on " <>
        "the tree's startup path. A child that calls back into #{mod}, or " <>
        "into anything not yet started, deadlocks the boot; terminate_child " <>
        "waits for the whole shutdown of the child.",
      at: Findings.at_site(site, mod),
      at_label: "this call blocks init until the supervisor answers",
      help: [
        "defer the call to `handle_continue/2`, so #{mod} is running and " <>
          "answering before it starts or stops anything"
      ]
    )
  end

  def finding(:init_waits_on_blocking_server, [mod, dep, handler, op_site]) do
    Findings.new(
      :warning,
      "init/1 waits on a server whose handler can block",
      "#{mod}.init/1 calls #{dep}, which is started earlier and is running " <>
        "by then — but #{handler} blocks on a supervisor shutdown or an " <>
        ":infinity call of its own, and while it does, #{dep} answers " <>
        "nobody. Every #{mod} init started in that window hangs behind " <>
        "it, and so does the supervisor starting them. A running callee is " <>
        "not an answering one.",
      at: Findings.at_mfa(mod, :init, 1),
      at_label: "this init waits on #{dep}",
      help: [
        "make #{dep}'s handler non-blocking (monitor and act on :DOWN " <>
          "instead of waiting), or move this call out of init/1 into " <>
          "`handle_continue/2`"
      ],
      related: [
        Findings.related("blocking handler", Findings.at_func(handler)),
        Findings.related("blocking call", Findings.at_site(op_site, dep))
      ]
    )
  end

  def finding(:init_deadlock_risk, [sup, child, dep, child_pos, dep_pos]) do
    Findings.new(
      :error,
      "Startup deadlock: init waits on a later sibling",
      "#{child} (position #{child_pos}) blocks in init/1 on #{dep}, which " <>
        "#{sup} only starts later (position #{dep_pos}). The supervisor " <>
        "cannot reach #{dep} until #{child}'s init returns, and #{child}'s " <>
        "init cannot return until #{dep} answers — the tree never finishes " <>
        "booting.",
      at: Findings.at_mfa(child, :init, 1),
      at_label: "this init blocks the start sequence",
      help: [
        "start `#{dep}` before `#{child}` in `#{sup}`'s child list " <>
          "(supervisors start children in order), or defer the call to " <>
          "`handle_continue/2`"
      ],
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("later dependency", Findings.at_module(dep))
      ]
    )
  end
end
