defmodule Argus.Analyses.Startup do
  @moduledoc """
  Work in a phase whose invariants do not hold yet.

  `init/1` runs inside the supervisor's start sequence and
  `handle_continue/2` runs before any message, so what either waits on
  decides whether the tree boots.

  - `blocks_on_peer(mod, phase, dep, kind, ordering, sup, site, detail)`
    — `init/1` or `handle_continue/2` waits on a peer the tree has not
    made ready: a synchronous `call` (to a sibling that starts `later`,
    a deadlock by construction; or one whose place is `unknown`, with
    `detail` saying whether every init takes the path), a `cast` to a
    later sibling, a `sup` management call, a `blocking_server` whose
    handler blocks without bound, the `parent` supervisor mid-start, a
    `global` lock or a `remote` operation on the boot path.
  - `unbounded_effect_in_init(mod, kind, api)` — init/1 reaches a socket
    `recv` with `:infinity`, or a `connect` nothing in the module can
    retry.
  - `deferral_defect(mod, kind, site, detail)` — the `{:ok, state, 0}`
    idiom any earlier message cancels (`init_timeout`), or a defensive
    catch in handle_continue that turns a deadlock into a restart loop
    (`continue_catch`). A mutual handle_continue cycle is blocking's
    `call_cycle` in the `continue` phase.
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
        name: :blocks_on_peer,
        fields: [
          {:mod, :symbol, "the child module (the init function, for global and remote)"},
          {:phase, :symbol, "init | continue"},
          {:dep, :symbol, "the peer waited on (empty for global and remote)"},
          {:kind, :symbol, "call | cast | sup | blocking_server | parent | global | remote"},
          {:ordering, :symbol, "later | earlier | parent | unknown, or empty"},
          {:sup, :symbol, "the supervisor placing both, when the ordering is known"},
          {:site, :symbol, "the tree definition for a later sibling, else the call site"},
          {:detail, :symbol,
           "conditional | unconditional for a call, api.op for sup, the handler for blocking_server, the op for global and remote"}
        ],
        # A supervisor call is one finding per operation, a blocking server
        # one per peer, a remote or global op one per op; the rest one per
        # (child, peer) under a supervisor, the synchronous row winning.
        key:
          {:kind,
           %{
             "sup" => [:mod, :detail],
             "blocking_server" => [:mod, :dep],
             "global" => [:mod, :detail],
             "remote" => [:mod, :detail],
             default: [:mod, :phase, :dep, :ordering, :sup]
           }},
        doc: "init/1 or handle_continue/2 waits on a peer the tree has not made ready."
      },
      %{
        name: :unbounded_effect_in_init,
        fields: [
          {:mod, :symbol, "module whose init/1 reaches it"},
          {:kind, :symbol, "recv | connect"},
          {:api, :symbol, "the receiving function, or the connect call"}
        ],
        key: {:kind, %{"connect" => [:mod], default: [:mod, :kind, :api]}},
        doc: "init/1 waits on a socket without bound, or connects with no way to retry."
      },
      %{
        name: :deferral_defect,
        fields: [
          {:mod, :symbol, "the module"},
          {:kind, :symbol, "init_timeout | continue_catch"},
          {:site, :symbol, "the init return, for init_timeout"},
          {:detail, :symbol, "the timeout in ms, or the supervisor for continue_catch"}
        ],
        key: [:mod, :kind, :site, :detail],
        doc: "Deferred startup work that will not happen as written."
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
  def finding(:unbounded_effect_in_init, [mod, "connect", api]) do
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

  def finding(:unbounded_effect_in_init, [mod, "recv", recv]) do
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

  def finding(:blocks_on_peer, [mod, "init", callee, "call", "unknown", _, _, "conditional"]) do
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

  def finding(:blocks_on_peer, [mod, "init", callee, "call", "unknown", _, _, "unconditional"]) do
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

  def finding(:blocks_on_peer, [mod, "init", target, "sup", _, _, site, api_op]) do
    target_text =
      case target do
        "dynamic" -> "a supervisor chosen at runtime"
        "via:" <> registry -> "a supervisor named through #{registry}"
        other -> other
      end

    Findings.new(
      :info,
      "init/1 makes a synchronous supervisor call",
      "#{mod}.init/1 reaches #{api_op} on #{target_text}. Every " <>
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

  def finding(:blocks_on_peer, [mod, "init", dep, "blocking_server", _, _, op_site, handler]) do
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

  def finding(:blocks_on_peer, [child, "init", dep, "call", "later", sup, sup_site, witness]) do
    Findings.new(
      :error,
      "Startup deadlock: init waits on a later sibling",
      "#{child} blocks in init/1 on #{dep}, which #{sup} only starts later. " <>
        "The supervisor cannot reach #{dep} until #{child}'s init returns, " <>
        "and #{child}'s init cannot return until #{dep} answers — the tree " <>
        "never finishes booting.",
      at: Findings.at_mfa(child, :init, 1),
      at_label: "this init blocks the start sequence",
      help: [
        "start `#{dep}` before `#{child}` in `#{sup}`'s child list " <>
          "(supervisors start children in order), or defer the call to " <>
          "`handle_continue/2`"
      ],
      related: [
        Findings.related("supervision tree defined here", Findings.at_site(sup_site, sup)),
        Findings.related("init-time call", Findings.at_func(witness)),
        Findings.related("later dependency", Findings.at_module(dep))
      ]
    )
  end

  def finding(:blocks_on_peer, [child, "init", dep, _kind, "later", sup, sup_site, witness]) do
    Findings.new(
      :warning,
      "Child starts before its dependency",
      "#{child} starts before #{dep} under #{sup}, yet depends on it. " <>
        "During startup, #{child} can run while #{dep} is not yet alive — " <>
        "calls into it fail until the tree finishes booting.",
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

  def finding(:blocks_on_peer, [caller, "continue", callee, "call", "later", sup, _, _]) do
    Findings.new(
      :warning,
      "handle_continue races a later sibling",
      "#{caller} sync-calls #{callee}, a later sibling, from handle_continue " <>
        "under #{sup}. The continue runs " <>
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

  def finding(:blocks_on_peer, [worker, "continue", sup, "parent", _, _, _, _]) do
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

  def finding(:deferral_defect, [mod, "init_timeout", site, "0"]) do
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

  def finding(:deferral_defect, [mod, "init_timeout", site, ms]) do
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

  def finding(:deferral_defect, [worker, "continue_catch", _, sup]) do
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

  def finding(:blocks_on_peer, [func, "init", _, "global", _, _, _, op]) do
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

  def finding(:blocks_on_peer, [func, "init", _, "remote", _, _, site, op]) do
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
