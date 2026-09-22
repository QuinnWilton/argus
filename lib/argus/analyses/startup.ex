defmodule Argus.Analyses.Startup do
  @moduledoc """
  Work in a phase whose invariants do not hold yet.

  `init/1` runs inside the supervisor's start sequence and
  `handle_continue/2` runs before any message, so what either waits on
  decides whether the tree boots.

  - `sync_call_in_init(mod, callee, kind)` — init/1 transitively makes a
    synchronous call; `kind` says whether every init takes the path.
  - `init_deadlock_risk(sup, child, dep, child_pos, dep_pos)` — the call
    is to a sibling that starts later: a deadlock by construction.
  - `wrong_start_order(sup, child, dep, ...)` — the structural statement
    of the same fact, at the tree definition.
  - `sup_call_in_init(mod, api, op, target, site)` — a synchronous
    supervisor management call from init/1.
  - `init_waits_on_blocking_server(mod, dep, handler, op_site)` — the
    callee is running, but one of its handlers blocks without bound.
  - `blocking_recv_in_init(mod, recv)` — init/1 reaches a socket receive
    with `:infinity`.
  - `connect_in_init_without_backoff(mod, api)` — init/1 connects and
    nothing in the module can retry.
  - `mutual_continue_deadlock`, `continue_to_later_sibling`,
    `continue_to_parent_supervisor`, `continue_crash_loop_risk`,
    `init_timeout_deferral` — the `handle_continue` shapes: a cycle, a
    race with a later sibling, a call back into the parent mid-start, a
    defensive catch that turns a deadlock into a restart loop, and the
    `{:ok, state, 0}` idiom any earlier message cancels.
  - `global_blocking_in_init(func, op)` and `distributed_in_init(func,
    op, site)` — a cluster-wide lock or a remote operation on the boot
    path.
  - `post_start_initialization(func, site, callee)` — shared state
    written after `Supervisor.start_link` returned.
  - `ignored_start_result(func, callee)` — a start result discarded.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :startup

  @impl true
  def description,
    do: "init/1 and handle_continue work that blocks, deadlocks or races the tree's start"

  @impl true
  def rules_file, do: "analyses/startup.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.Supervision,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.CallArgs,
      Argus.Extractors.Purity,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.GenStatem,
      Argus.Extractors.Reply,
      Argus.Extractors.Monitor,
      Argus.Extractors.ProcessRegistry
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :connect_in_init_without_backoff,
        fields: [
          {:mod, :symbol, "module whose init/1 connects"},
          {:api, :symbol, "the connect call reached"}
        ],
        key: [:mod],
        doc: "init/1 connects to a dependency and the module has no timer or continue to retry."
      },
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
      },
      %{
        name: :wrong_start_order,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:child, :symbol, "child module"},
          {:dep, :symbol, "dependency module"},
          {:child_pos, :number, "child start position"},
          {:dep_pos, :number, "dependency start position"},
          {:sup_site, :symbol, "instruction ID of the tree definition"},
          {:witness, :symbol, "the child's init/1, where the call originates"}
        ],
        key: [:sup, :child, :dep],
        doc: "Child starts before its dependency."
      },
      %{
        name: :mutual_continue_deadlock,
        fields: [
          {:mod_a, :symbol, "first module in the mutual cycle"},
          {:mod_b, :symbol, "second module in the mutual cycle"}
        ],
        doc:
          "Two modules whose handle_continue clauses sync-call each other — both children stay alive but neither processes its mailbox."
      },
      %{
        name: :continue_to_later_sibling,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:caller, :symbol, "child whose handle_continue makes the call"},
          {:callee, :symbol, "later-started sibling being called"},
          {:caller_pos, :number, "caller's start position in the supervisor"},
          {:callee_pos, :number, "callee's start position in the supervisor"}
        ],
        doc:
          "handle_continue races against a sibling started at a later position in the same supervisor's child list."
      },
      %{
        name: :continue_to_parent_supervisor,
        fields: [
          {:worker, :symbol, "worker whose handle_continue makes the call"},
          {:sup, :symbol, "the parent supervisor being called"}
        ],
        doc:
          "handle_continue calls back into the parent supervisor while it's still mid-start_link."
      },
      %{
        name: :init_timeout_deferral,
        fields: [
          {:mod, :symbol, "module whose init/1 returns a timeout"},
          {:site, :symbol, "the return site"},
          {:timeout_ms, :number, "the literal timeout"}
        ],
        doc:
          "init/1 returns {:ok, state, timeout}: deferred work that any earlier message cancels."
      },
      %{
        name: :continue_crash_loop_risk,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:worker, :symbol, "worker module with defensive try/catch around the continue call"}
        ],
        doc:
          "Defensive try/catch :exit suppresses the literal deadlock but creates a supervisor restart loop."
      },
      %{
        name: :global_blocking_in_init,
        fields: [
          {:func, :symbol, "init function (or transitively reachable from one)"},
          {:op, :symbol, ":global operation"}
        ],
        doc: "Blocking :global op reachable from init/1 — hangs supervisor startup on netsplit."
      },
      %{
        name: :distributed_in_init,
        fields: [
          {:func, :symbol, "init function"},
          {:op, :symbol, "operation"},
          {:site, :symbol, "instruction ID of the operation inside init"}
        ],
        key: [:func, :op],
        doc: "Distributed operation in init/1 blocking supervisor startup."
      },
      %{
        name: :post_start_initialization,
        fields: [
          {:func, :symbol, "function that started the tree"},
          {:site, :symbol, "the call after Supervisor.start_link"},
          {:callee, :symbol, "what the call reaches that writes shared state"}
        ],
        key: [:func, :site],
        doc: "Shared state written after Supervisor.start_link returned."
      },
      %{
        name: :ignored_start_result,
        fields: [
          {:func, :symbol, "calling function"},
          {:callee, :symbol, "start function"}
        ],
        doc: "GenServer/Supervisor start result not pattern matched."
      }
    ]
  end

  @impl true
  def finding(:connect_in_init_without_backoff, [mod, api]) do
    Findings.new(
      :warning,
      "init/1 connects with no reconnect path",
      "#{mod}'s init/1 reaches #{api}, and nothing in the module arms a timer " <>
        "or continues after init to try again. When the dependency is not " <>
        "there yet, init fails, the supervisor restarts the child at once, and " <>
        "after max_restarts the tree — usually the application — goes down at boot.",
      at: Findings.at_mfa(mod, :init, 1),
      at_label: "connects from here",
      help: [
        "return `{:ok, state, {:continue, :connect}}` and connect in handle_continue/2 with a backoff timer",
        "or start `:transient` and retry from a timer message"
      ]
    )
  end

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

  def finding(:wrong_start_order, [sup, child, dep, child_pos, dep_pos, sup_site, witness]) do
    Findings.new(
      :warning,
      "Child starts before its dependency",
      "#{child} (position #{child_pos}) starts before #{dep} (position #{dep_pos}) " <>
        "under #{sup}, yet depends on it. During startup, #{child} can run while " <>
        "#{dep} is not yet alive — calls into it fail until the tree finishes " <>
        "booting.",
      at: Findings.at_site(sup_site, sup),
      at_label: "supervision tree defined here",
      help: [
        "move `#{dep}` before `#{child}` in the child list — supervisors " <>
          "start children in order"
      ],
      related: [
        Findings.related("init-time call", Findings.at_func(witness)),
        Findings.related("dependency", Findings.at_module(dep))
      ]
    )
  end

  def finding(:mutual_continue_deadlock, [mod_a, mod_b]) do
    Findings.new(
      :error,
      "Mutual handle_continue deadlock",
      "#{mod_a} and #{mod_b} sync-call each other from handle_continue/2. " <>
        "Both return from init — the supervisor proceeds happily — then each " <>
        "blocks calling the other before ever reading its own mailbox. " <>
        "Neither can reply; both calls time out, forever, on every boot.",
      at: Findings.at_mfa(mod_a, :handle_continue, 2),
      at_label: "one side of the cycle blocks here",
      help: [
        "break the cycle: keep one direction synchronous and make the other " <>
          "asynchronous (a cast, or a message each side processes once both " <>
          "are up)"
      ],
      related: [Findings.related("cycle partner", Findings.at_mfa(mod_b, :handle_continue, 2))]
    )
  end

  def finding(:continue_to_later_sibling, [sup, caller, callee, caller_pos, callee_pos]) do
    Findings.new(
      :warning,
      "handle_continue races a later sibling",
      "#{caller} (position #{caller_pos}) sync-calls #{callee} (position " <>
        "#{callee_pos}) from handle_continue under #{sup}. The continue runs " <>
        "concurrently with the supervisor's start sequence, so whether " <>
        "#{callee} is alive when the call lands is a boot-time race — it " <>
        "works on the fast machine and fails in CI.",
      at: Findings.at_mfa(caller, :handle_continue, 2),
      at_label: "the racing call originates here",
      help: [
        "start `#{callee}` before `#{caller}` in `#{sup}`'s child list, or " <>
          "make `#{caller}` tolerate `#{callee}`'s absence (retry with " <>
          "backoff, or monitor and wait for it to register)"
      ],
      related: [
        Findings.related("supervisor", Findings.at_module(sup)),
        Findings.related("later sibling", Findings.at_module(callee))
      ]
    )
  end

  def finding(:continue_to_parent_supervisor, [worker, sup]) do
    Findings.new(
      :warning,
      "handle_continue calls its own supervisor",
      "#{worker}'s handle_continue sync-calls its parent #{sup} while the " <>
        "supervisor may still be mid-start_link, not yet reading its mailbox. " <>
        "The worker blocks until the whole child list finishes starting — and " <>
        "if any later child waits on #{worker}, startup deadlocks.",
      at: Findings.at_mfa(worker, :handle_continue, 2),
      at_label: "calls the parent supervisor here",
      help: [
        "move the supervisor query out of startup: pass the information as " <>
          "an init argument, or query later from a message sent once the " <>
          "tree is up"
      ],
      related: [Findings.related("parent supervisor", Findings.at_module(sup))]
    )
  end

  def finding(:init_timeout_deferral, [mod, site, "0"]) do
    Findings.new(
      :info,
      "init/1 defers work with a zero timeout",
      "#{mod}.init/1 returns {:ok, state, 0}, the pre-handle_continue " <>
        "idiom for finishing initialisation once the supervisor has moved " <>
        "on. The :timeout message only arrives if nothing else is in the " <>
        "mailbox first: any message — a datagram on a socket init opened, " <>
        "a PubSub broadcast init subscribed to, a call from the starter — " <>
        "cancels it, and the deferred work silently never runs.",
      at: Findings.at_site(site, mod),
      at_label: "this timeout is cancelled by any earlier message",
      help: [
        "return `{:ok, state, {:continue, :finish_init}}` and move the work " <>
          "to `handle_continue(:finish_init, state)`, which runs before any " <>
          "message is processed"
      ]
    )
  end

  def finding(:init_timeout_deferral, [mod, site, ms]) do
    Findings.new(
      :info,
      "init/1 relies on a #{ms}ms idle timeout",
      "#{mod}.init/1 returns {:ok, state, #{ms}}. The :timeout message " <>
        "fires only after #{ms}ms of an empty mailbox, and every message " <>
        "that arrives restarts nothing — the callback must return the " <>
        "timeout again or it is gone. If the work behind :timeout must " <>
        "happen, a timer (Process.send_after/3) or handle_continue/2 is " <>
        "the reliable shape; an idle timeout is for reacting to silence.",
      at: Findings.at_site(site, mod),
      at_label: "this timeout is cancelled by any earlier message"
    )
  end

  def finding(:continue_crash_loop_risk, [sup, worker]) do
    Findings.new(
      :warning,
      "Defensive continue turns deadlock into a restart loop",
      "#{worker} wraps its handle_continue sync call in try/catch :exit. The " <>
        "catch suppresses the deadlock symptom, but the call still fails " <>
        "during the startup race — so #{worker} either initializes with wrong " <>
        "state or crashes and restarts repeatedly under #{sup}, hiding the " <>
        "real ordering bug.",
      at: Findings.at_mfa(worker, :handle_continue, 2),
      at_label: "the defensive catch hides the race here",
      help: [
        "remove the try/catch and fix the ordering it papers over: start the " <>
          "callee earlier in the child list, or retry the call with backoff " <>
          "until the callee is up"
      ],
      related: [Findings.related("supervisor", Findings.at_module(sup))]
    )
  end

  def finding(:global_blocking_in_init, [func, op]) do
    Findings.new(
      :error,
      "Cluster-wide lock during init",
      "#{func} reaches :global.#{op} from init/1. init blocks the " <>
        "supervisor's start sequence, and the :global op blocks on " <>
        "cluster-wide agreement — local startup now hangs whenever the " <>
        "cluster is partitioned or slow. Defer to handle_continue.",
      at: Findings.at_func(func)
    )
  end

  def finding(:distributed_in_init, [func, op, site]) do
    Findings.new(
      :warning,
      "Distributed operation in init/1",
      "#{func} performs #{op} during init, while the supervisor's start " <>
        "sequence waits. A slow or partitioned peer stalls local startup; " <>
        "defer remote work to handle_continue so the tree boots without the " <>
        "network.",
      at: Findings.at_instr(site)
    )
  end

  def finding(:post_start_initialization, [func, site, callee]) do
    Findings.new(
      :info,
      "Shared state written after the tree is up",
      "#{func} calls Supervisor.start_link and only afterwards reaches #{callee}, " <>
        "which writes state (a persistent_term, an ETS row, application env). " <>
        "The children are already running when that write lands; one that reads " <>
        "the state in the meantime finds nothing there.",
      at: Findings.at_site(site, func),
      at_label: "the tree is already running here",
      help: [
        "perform the initialization before Supervisor.start_link, or as the first " <>
          "child (a child spec whose start function does the work and returns :ignore)"
      ]
    )
  end

  def finding(:ignored_start_result, [func, callee]) do
    Findings.new(
      :warning,
      "Start result ignored",
      "#{func} calls #{callee} and discards the result. An {:error, reason} " <>
        "return goes unnoticed — the process isn't running, and the first " <>
        "symptom is a crash later at a call site that assumed it was.",
      at: Findings.at_func(func)
    )
  end
end
