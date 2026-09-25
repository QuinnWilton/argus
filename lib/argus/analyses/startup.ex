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
    `global` lock that retries (`dep` says whether it waits on the
    `cluster`, only the `local` node, or an `unknown` node list) or a
    `remote` operation on the boot path.
  - `unbounded_effect_in_init(mod, kind, api, site)` — init/1, in its own
    process, reaches a socket `recv` with `:infinity`, a `receive` with no
    `after` (`down` when only the exit of the process it waits on ends
    it), a server loop it enters before acknowledging its start
    (`enter_loop`), or a `connect` nothing in the module can retry.
  - `deferral_defect(mod, kind, site, detail)` — the `{:ok, state, 0}`
    idiom any earlier message cancels (`init_timeout`), or a defensive
    catch in handle_continue that turns a deadlock into a restart loop
    (`continue_catch`). A mutual handle_continue cycle is blocking's
    `call_cycle` in the `continue` phase.
  - `post_start_initialization(func, site, callee, start)` — shared state
    written after `Supervisor.start_link` returned.
  - `ignored_start_result(func, callee)` — a start result discarded.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :startup

  @impl true
  def description,
    do: "work in init/1 or handle_continue/2 that blocks, deadlocks or races the tree's start"

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
      Argus.Extractors.ProcessRegistry,
      # A call whose target is a pid resolves through process points-to
      # (clientlib/processes.dl, in the points-to stage): where the pid was
      # started, and names.
      Argus.Extractors.PidFlow,
      # A call with a literal first argument enters only the clauses that
      # match it (clientlib/global_reach.dl's lock walk).
      Argus.Extractors.ClauseCall
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :blocks_on_peer,
        fields: [
          {:mod, :symbol, "the child module (the init function, for global and remote)"},
          {:phase, :symbol, "init | continue"},
          {:dep, :symbol,
           "the peer waited on; for global, the nodes the lock waits on (cluster | local | unknown); empty for remote"},
          {:kind, :symbol,
           "call | cast | sup | blocking_server | parent | global | global_assumed | global_bounded | remote"},
          {:ordering, :symbol, "later | earlier | parent | unknown, or empty"},
          {:sup, :symbol, "the supervisor placing both, when the ordering is known"},
          {:site, :symbol, "the tree definition for a later sibling, else the call site"},
          {:detail, :symbol,
           "conditional | unconditional for a call, api.op for sup, the handler for blocking_server, the op for global and remote"}
        ],
        # A supervisor call is one finding per operation, a blocking server
        # one per peer, a remote op one per op, a global op one per op and
        # node list (a local and a cluster-wide lock say different things);
        # the rest one per (child, peer) under a supervisor, the synchronous
        # row winning.
        key:
          {:kind,
           %{
             "sup" => [:mod, :detail],
             "blocking_server" => [:mod, :dep],
             "global" => [:mod, :dep, :detail],
             "global_assumed" => [:mod, :dep, :detail],
             "global_bounded" => [:mod, :dep, :detail],
             "remote" => [:mod, :detail],
             default: [:mod, :phase, :dep, :ordering, :sup]
           }},
        doc: "init/1 or handle_continue/2 waits on a peer the tree has not made ready."
      },
      %{
        name: :unbounded_effect_in_init,
        fields: [
          {:mod, :symbol, "module whose init/1 reaches it"},
          {:kind, :symbol, "recv | receive | down | enter_loop | connect"},
          {:api, :symbol,
           "the receiving function, the function entering the loop, or the connect call"},
          {:site, :symbol,
           "the socket recv or the receive, when the instruction is known; else empty"},
          {:peer, :symbol,
           "for receive and down, 'local' when a prior is sure what the receive waits on " <>
             "answers from inside the node; else empty"},
          {:permille, :number, "the prior's probability in thousandths, else 0"}
        ],
        # One wait finding per waiting function: the inits that reach it
        # are its evidence frames.
        key:
          {:kind,
           %{
             "connect" => [:mod],
             "recv" => [:kind, :api],
             "receive" => [:kind, :api],
             "down" => [:kind, :api],
             "enter_loop" => [:mod, :site]
           }},
        doc:
          "init/1 waits on a socket or its mailbox without bound, enters its loop before its " <>
            "start is acknowledged, or connects with no way to retry."
      },
      %{
        name: :init_reaches_recv,
        fields: [
          {:mod, :symbol, "module whose init/1 reaches the receive"},
          {:api, :symbol, "the receiving function"},
          {:call, :symbol,
           "the call in init/1 that starts its path there, else empty (init/1 receives itself)"}
        ],
        key: [:mod, :api],
        earliest: :call,
        evidence: %{of: :unbounded_effect_in_init, on: [:api]},
        doc: "The init/1 callbacks that reach an unbounded receive, attached to its finding."
      },
      %{
        name: :init_lock_path,
        fields: [
          {:init, :symbol, "the init/1 that reaches the lock"},
          {:lock, :symbol, "the :global call, in a helper"},
          {:call, :symbol, "the call in init/1 that starts its path there, else empty"}
        ],
        key: [:init, :lock],
        earliest: :call,
        evidence: %{of: :blocks_on_peer, on: [init: :mod, lock: :site]},
        doc: "Where init/1's path to a :global lock in a helper begins."
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
          {:callee, :symbol, "what the call reaches that writes shared state"},
          {:start, :symbol, "the Supervisor.start_link call, else empty"}
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

  # A receive the model is sure waits on something inside the node that
  # always answers (`Argus.Priors.Questions.PeerAnswers`): a heuristic
  # finding a step down. No prior, no change.
  defp answering(attrs, _recv, "", _p), do: attrs

  defp answering(attrs, recv, "local", p) do
    Findings.heuristic(
      attrs,
      String.to_integer(p),
      "what #{Findings.call_name(recv)} waits on answers from inside the node"
    )
  end

  @impl true
  def finding(:unbounded_effect_in_init, [mod, "connect", api, _site, _, _]) do
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

  def finding(:unbounded_effect_in_init, [_mod, "recv", recv, site, _, _]) do
    Findings.new(
      :warning,
      "init/1 waits on a socket with no timeout",
      "#{recv} waits on a socket with :infinity, and init/1 reaches it " <>
        "in its own process. Until the message arrives, the " <>
        "process is not started: its supervisor's start, and whoever called " <>
        "start_child, wait with it — for as long as the server stays silent.",
      at: Findings.at_site_in_func(site, recv),
      at_label: "receives with :infinity",
      help: [
        "bound the receive (a connect timeout) and fail the start with an error",
        "or connect after init returns (`{:continue, :connect}`) so the start completes"
      ]
    )
  end

  def finding(:unbounded_effect_in_init, [_mod, "receive", recv, site, peer, p]) do
    Findings.new(
      :warning,
      "init/1 waits on a message with no timeout",
      "#{Findings.call_name(recv)} has a `receive` with no `after`, and init/1 reaches " <>
        "it in its own process. Until the message arrives, the process is not " <>
        "started: its supervisor's start, and whoever called start_child, wait " <>
        "with it — forever, if the sender is gone or never sends.",
      at: Findings.at_site_in_func(site, recv),
      at_label: "waits with no `after`",
      at_source: "receive",
      to_block: :receive,
      help: [
        "add an `after` and fail the start with an error when it fires",
        "or wait after init returns (`{:continue, :await}`) so the start completes"
      ]
    )
    |> answering(recv, peer, p)
  end

  def finding(:unbounded_effect_in_init, [_mod, "down", recv, site, peer, p]) do
    Findings.new(
      :info,
      "init/1 waits on another process with no timeout",
      "#{Findings.call_name(recv)} has a `receive` with no `after`, and init/1 reaches " <>
        "it in its own process. The wait takes the exit of the process it waits " <>
        "on, so it ends if that process dies; while it lives and does not answer, " <>
        "the process is not started: its supervisor's start, and whoever called " <>
        "start_child, wait with it.",
      at: Findings.at_site_in_func(site, recv),
      at_label: "waits until the other process answers or exits",
      at_source: "receive",
      to_block: :receive,
      help: [
        "add an `after` and fail the start with an error when it fires",
        "or wait after init returns (`{:continue, :await}`) so the start completes"
      ]
    )
    |> answering(recv, peer, p)
  end

  def finding(:unbounded_effect_in_init, [mod, "enter_loop", func, site, _, _]) do
    Findings.new(
      :error,
      "init/1 enters the server loop before its start returns",
      "#{mod}'s init/1 reaches `enter_loop` in #{Findings.call_name(func)} without " <>
        "calling `:proc_lib.init_ack/1` first. The process that started it waits for " <>
        "init/1 to return (GenServer.start_link) or to acknowledge the start " <>
        "(`:proc_lib.start_link`), and enter_loop never returns: the start never " <>
        "completes, and the supervisor's start hangs with it.",
      at: Findings.at_site_in_func(site, func),
      at_label: "never returns, and nothing acknowledged the start",
      help: [
        "start the process with `:proc_lib.start_link/3` and call " <>
          "`:proc_lib.init_ack({:ok, self()})` before `enter_loop`",
        "or return `{:ok, state}` from init/1 and let the behaviour run the loop"
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

  def finding(:blocks_on_peer, [worker, "continue", sup, "parent", _, _, site, detail]) do
    how = if detail == "", do: "sync-calls", else: "calls #{detail} on"

    Findings.new(
      :warning,
      "handle_continue calls its own supervisor",
      "#{worker}'s handle_continue #{how} its parent #{sup} while the " <>
        "supervisor is still starting the children after it, not yet reading " <>
        "its mailbox. The worker blocks until the rest of the child list is " <>
        "up — and if any later child waits on #{worker}, startup deadlocks.",
      at:
        if(site == "",
          do: Findings.at_mfa(worker, :handle_continue, 2),
          else: Findings.at_site(site, worker)
        ),
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
      # The return tuple has no line marker of its own: the bytecode's
      # line is the last call's before it.
      at_source: "0}",
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
      "init/1 relies on an idle timeout",
      "#{mod}.init/1 returns {:ok, state, #{ms}}. The :timeout message " <>
        "fires only after #{ms}ms of an empty mailbox, and every message " <>
        "that arrives restarts nothing — the callback must return the " <>
        "timeout again or it is gone. An idle timeout is for reacting to " <>
        "silence.",
      at: Findings.at_site(site, mod),
      at_source: "#{ms}}",
      at_label: "this timeout is cancelled by any earlier message",
      help: [
        "for work that must happen, arm a timer (Process.send_after/3) or " <>
          "return `{:continue, _}` from init/1"
      ]
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

  # A lock that retries until it is granted ("global"), or whose retry
  # count the bytecode does not show and is assumed :infinity
  # ("global_assumed"). Its node list decides what it waits on: the
  # connected nodes ("cluster"), this node's global server alone
  # ("local"), or a list the bytecode does not show ("unknown", reported
  # as the cluster-wide lock it may be, saying it is assumed).
  def finding(:blocks_on_peer, [func, "init", nodes, kind, _, _, site, op])
      when kind in ["global", "global_assumed"] do
    init_lock(func, nodes, kind == "global_assumed", site, op)
  end

  # A positive retry count over other nodes: it gives up, but each try
  # waits on every node in the list.
  def finding(:blocks_on_peer, [func, "init", nodes, "global_bounded", _, _, site, op]) do
    assumed = nodes != "cluster"

    Findings.new(
      :warning,
      "Bounded cluster-wide lock during init",
      "#{func} reaches :global.#{op} from init/1 with a bounded retry count" <>
        if(assumed,
          do:
            ", and a node list the bytecode does not show, so this assumes it holds the connected nodes. ",
          else: ". "
        ) <>
        "It gives up and returns false once its retries are spent, after up to 8 s of " <>
        "backoff between tries, but each try asks every node in the list: a node that is " <>
        "partitioned and not yet declared down holds the try, and init, and the " <>
        "supervisor's start sequence, wait with it.",
      at: Findings.at_site_in_func(site, func),
      at_label:
        if(assumed,
          do:
            "bounded lock reached from init/1; its node list could not be read, so assumed cluster-wide",
          else: "bounded cluster-wide lock reached from init/1"
        ),
      help: ["defer the lock to handle_continue/2 so the start completes without the cluster"]
    )
  end

  def finding(:blocks_on_peer, [func, "init", _, "remote", _, _, site, op]) do
    Findings.new(
      :warning,
      "Distributed operation in init/1",
      "#{func} performs #{op} during init, while the supervisor's start " <>
        "sequence waits. A slow or partitioned peer stalls local startup.",
      at: Findings.at_instr(site),
      at_label: "remote operation during init/1",
      help: ["defer remote work to handle_continue/2 so the tree boots without the network"]
    )
  end

  def finding(:post_start_initialization, [func, site, callee, start]) do
    Findings.new(
      :info,
      "Shared state written after the tree is up",
      "#{func} calls Supervisor.start_link and only afterwards reaches #{callee}, " <>
        "which writes state (a persistent_term, an ETS row, application env). " <>
        "The children are already running when that write lands; one that reads " <>
        "the state in the meantime finds nothing there.",
      at: Findings.at_site_in_func(site, func),
      at_label: "the tree is already running here",
      related:
        if(start == "",
          do: [],
          else: [Findings.related("the tree starts here", Findings.at_site_in_func(start, func))]
        ),
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
      at: Findings.at_func(func),
      at_label: "start result discarded here",
      help: ["match `{:ok, pid}` and handle `{:error, reason}`"]
    )
  end

  # The frame points at the call that starts init/1's path, the line a
  # reader follows; init/1's head only when the path leaves through no
  # call instruction. A lock in init/1 itself has no row: the anchor
  # already says so.
  @impl true
  def evidence(:init_lock_path, [init, _lock, ""]) do
    Findings.related("init/1 reaches it from here", Findings.at_func(init))
  end

  def evidence(:init_lock_path, [init, _lock, call]) do
    Findings.related("init/1 reaches it from here", Findings.at_site_in_func(call, init))
  end

  def evidence(:init_reaches_recv, [mod, _api, ""]) do
    Findings.related("reached from #{mod}.init/1", Findings.at_mfa(mod, :init, 1))
  end

  def evidence(:init_reaches_recv, [mod, _api, call]) do
    Findings.related("reached from #{mod}.init/1", Findings.at_site(call, mod))
  end

  defp init_lock(func, "cluster", assumed_retries, site, op) do
    Findings.new(
      :error,
      "Cluster-wide lock during init",
      "#{func} reaches :global.#{op} from init/1. init blocks the " <>
        "supervisor's start sequence, and the :global op blocks on " <>
        "cluster-wide agreement — local startup now hangs whenever the " <>
        "cluster is partitioned or slow." <> assumed_retries_sentence(assumed_retries),
      at: Findings.at_site_in_func(site, func),
      at_label: "cluster-wide lock reached from init/1" <> assumed_retries_label(assumed_retries),
      help: ["defer the lock to handle_continue/2 so the start completes without the cluster"]
    )
  end

  # [node()]: only this node's global server takes part. The lock does
  # not wait on the cluster, but it still retries until it is free.
  defp init_lock(func, "local", assumed_retries, site, op) do
    Findings.new(
      :warning,
      "Lock during init",
      "#{func} reaches :global.#{op} from init/1, over only the local " <>
        "node. No other node takes part, so the cluster cannot stall it, " <>
        "but the lock retries until it is free: init, and the supervisor's " <>
        "start sequence with it, waits for as long as another process on " <>
        "this node holds the lock." <> assumed_retries_sentence(assumed_retries),
      at: Findings.at_site_in_func(site, func),
      at_label:
        "lock reached from init/1; it waits on this node's holders" <>
          assumed_retries_label(assumed_retries),
      help: [
        "defer the lock to handle_continue/2, or bound its retries " <>
          "(:global.set_lock/3) so a held lock fails the start instead of hanging it"
      ]
    )
  end

  # "unknown": the node list is not in the bytecode (a parameter, a
  # call's result). Reported as the cluster-wide lock it may be, saying
  # it is assumed — as is any list not known to be local or cluster.
  defp init_lock(func, _nodes, assumed_retries, site, op) do
    Findings.new(
      :error,
      "Cluster-wide lock during init",
      "#{func} reaches :global.#{op} from init/1, with a node list the " <>
        "bytecode does not show, so this assumes it holds the connected " <>
        "nodes. init blocks the supervisor's start sequence, and a lock " <>
        "over the cluster blocks on cluster-wide agreement — local startup " <>
        "then hangs whenever the cluster is partitioned or slow. A list of " <>
        "only [node()] waits on this node's holders alone." <>
        assumed_retries_sentence(assumed_retries),
      at: Findings.at_site_in_func(site, func),
      at_label:
        if(assumed_retries,
          do:
            "lock reached from init/1; its node list and retry count could not be read, " <>
              "so assumed cluster-wide and :infinity",
          else:
            "lock reached from init/1; its node list could not be read, so assumed cluster-wide"
        ),
      help: ["defer the lock to handle_continue/2 so the start completes without the cluster"]
    )
  end

  defp assumed_retries_sentence(false), do: ""

  defp assumed_retries_sentence(true) do
    " Its retry count is not in the bytecode (a parameter, an option), so " <>
      "this assumes :infinity, the default; a positive count gives up and " <>
      "returns false instead."
  end

  defp assumed_retries_label(false), do: ""

  defp assumed_retries_label(true),
    do: "; its retry count could not be read, so assumed :infinity"
end
