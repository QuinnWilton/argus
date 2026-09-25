defmodule Argus.Analyses.Shutdown do
  @moduledoc """
  Cleanup that cannot run, or teardown that hurts a peer.

  OTP's rule for `terminate/2` is narrower than it reads: it runs when a
  callback returns `{:stop, ...}` or raises, and on a supervisor shutdown
  only if the process traps exits. Tests miss it because
  `GenServer.stop/1` exercises the path that does run terminate.

  - `cleanup_defect(mod, behaviour, kind, category, api, via)` — what
    goes wrong with terminate/2's cleanup: `never_runs` (durable cleanup,
    and the process does not trap exits), `unclear` (work the effect
    model cannot classify, skipped the same way) or `truncated` (the
    module traps, but the cleanup has no bound of its own inside the
    shutdown timeout).
  - `unhandled_exit_signal(mod, kind, witness)` — the process traps exits
    and nothing takes the `{:EXIT, ...}` message that trapping turns
    them into: `no_handler`, or `no_exit_clause` in the handle_info it
    has.
  - `teardown_touches_sibling(mod, sibling, phase, kind, via, sup,
    handler, site, sup_site)` —
    terminate/2 waits on a sibling that may already be gone (`terminate`,
    `call`), or a handler stops a sibling the supervisor owns (`handler`,
    `stop`).
  - `foreign_dynamic_children(mod, sup, via, site, sup_site)` — children started under a
    DynamicSupervisor in another tree outlive this one.
  - `kills_monitored_child(mod, site, kill_site)` — a server terminates a
    process it still monitors, so the `:DOWN` reads as a crash.
  - `permanent_child_stops_normally(sup, child, reason, site, sup_site)`
    — a permanent child returns `{:stop, :normal, ...}` and is started
    straight back.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :shutdown

  @impl true
  def description, do: "cleanup a supervisor shutdown will skip, and teardown that hurts a peer"

  @impl true
  def rules_file, do: "analyses/shutdown.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Purity,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.Supervision,
      Argus.Extractors.CallbackTag,
      Argus.Extractors.CallArgs,
      Argus.Extractors.GenStatem,
      Argus.Extractors.Monitor,
      Argus.Extractors.Reply,
      # The calls in terminate/2 that a supervisor's :shutdown never runs.
      Argus.Extractors.ClauseCall,
      # A call whose target is a pid resolves through process points-to
      # (clientlib/processes.dl, in the points-to stage): where the pid was
      # started, and names.
      Argus.Extractors.PidFlow,
      Argus.Extractors.ProcessRegistry
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :cleanup_defect,
        fields: [
          {:mod, :symbol, "the module"},
          {:behaviour, :symbol, "the behaviour providing terminate/2"},
          {:kind, :symbol, "never_runs | unclear | truncated"},
          {:category, :symbol, "the kind of cleanup (empty for unclear)"},
          {:api, :symbol, "the call performing it"},
          {:via, :symbol, "the function performing it"}
        ],
        # A row is one cleanup call; the finding is that the module's
        # terminate/2 does such work at all, and cleanup_site frames every
        # call of it.
        key: [:mod, :kind],
        doc: "terminate/2 cleanup a supervisor shutdown skips, cannot classify, or truncates."
      },
      %{
        name: :cleanup_site,
        fields: [
          {:mod, :symbol, "the module"},
          {:kind, :symbol, "never_runs | unclear | truncated, as its cleanup_defect"},
          {:api, :symbol, "the call performing the cleanup"},
          {:via, :symbol, "the function making it"},
          {:site, :symbol, "the call"}
        ],
        key: [:mod, :kind, :site],
        evidence: %{of: :cleanup_defect, on: [:mod, :kind]},
        doc: "Every call a module's cleanup_defect finding is about, where it is."
      },
      %{
        name: :teardown_touches_sibling,
        fields: [
          {:mod, :symbol, "the process whose teardown touches the sibling"},
          {:sibling, :symbol,
           "the sibling: a child of sup (a handler's stop), or a module in another of its branches (terminate)"},
          {:phase, :symbol, "terminate | handler"},
          {:kind, :symbol,
           "call | call_restart | call_unordered (order or strategy unknown) | stop"},
          {:via, :symbol, "function performing the call or stop"},
          {:sup, :symbol, "the supervisor both sit under, where their branches meet"},
          {:handler, :symbol, "the callback of mod the row belongs to"},
          {:site, :symbol, "the call that makes the dependency, when direct; else empty"},
          {:sup_site, :symbol, "where the supervisor places both, else empty"}
        ],
        key: [:mod, :sibling, :phase],
        doc:
          "terminate/2 waits on a sibling that may be gone, or a handler stops one the supervisor owns."
      },
      %{
        name: :terminate_path,
        fields: [
          {:handler, :symbol, "the terminate/2 that reaches the helper"},
          {:via, :symbol, "the helper that calls the sibling"},
          {:call, :symbol, "the call in terminate/2 that starts its path there, else empty"}
        ],
        key: [:handler, :via],
        earliest: :call,
        evidence: %{of: :teardown_touches_sibling, on: [:handler, :via]},
        doc: "Where terminate/2's path to a helper that calls a sibling begins."
      },
      %{
        name: :foreign_dynamic_children,
        fields: [
          {:mod, :symbol, "module that starts the children"},
          {:sup, :symbol, "the DynamicSupervisor they are started under"},
          {:via, :symbol, "function that calls start_child"},
          {:site, :symbol, "the start_child call, else empty"},
          {:sup_site, :symbol, "where the other tree defines the supervisor, else empty"}
        ],
        key: [:mod, :sup],
        doc:
          "A process starts children under a DynamicSupervisor in another tree " <>
            "and its terminate/2 does not stop them."
      },
      %{
        name: :unhandled_exit_signal,
        fields: [
          {:mod, :symbol, "module"},
          {:kind, :symbol, "no_handler | no_exit_clause"},
          {:witness, :symbol, "function that sets trap_exit"}
        ],
        key: [:mod, :kind],
        doc: "Module traps exits and nothing takes the {:EXIT, ...} message that makes."
      },
      %{
        name: :kills_monitored_child,
        fields: [
          {:mod, :symbol, "the server module"},
          {:site, :symbol, "a monitor call site in its callbacks"},
          {:kill_site, :symbol, "the terminate_child or GenServer.stop call"}
        ],
        key: [:mod, :kill_site],
        doc: "A server terminates a process it monitors without demonitoring first."
      },
      %{
        name: :permanent_child_stops_normally,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:child, :symbol, "the permanent child"},
          {:reason, :symbol, "the literal stop reason: ':normal' or ':shutdown'"},
          {:site, :symbol, "the {:stop, ...} return site in the child"},
          {:sup_site, :symbol, "the instruction that defines the tree"}
        ],
        key: [:sup, :child],
        doc:
          "A permanent child returns {:stop, :normal | :shutdown, ...}; the supervisor restarts it."
      }
    ]
  end

  @impl true
  def finding(:cleanup_defect, [mod, behaviour, "never_runs", category, api, via]) do
    Findings.new(
      :error,
      "#{mod} cleans up in terminate/2 but never traps exits",
      "#{via} calls #{api} — #{phrase(category)} — from #{mod}'s terminate/2. " <>
        "A #{behaviour} only runs terminate/2 when a callback returns {:stop, ...} " <>
        "or raises. On a supervisor shutdown the parent sends an exit signal, and " <>
        "a process that is not trapping exits dies immediately: terminate/2 is " <>
        "never called and this cleanup is silently skipped. " <>
        "That is the normal way processes stop, so it is the case the cleanup was " <>
        "presumably written for. Tests miss it because GenServer.stop/1 exercises " <>
        "the path that does run terminate.",
      at: Findings.at_func("#{mod}:terminate/2"),
      at_label: "runs only on {:stop, _} or a crash",
      help: [
        "add `Process.flag(:trap_exit, true)` in init/1, and keep the work inside " <>
          "the child's shutdown timeout"
      ]
    )
  end

  def finding(:cleanup_defect, [mod, behaviour, "unclear", _, api, via]) do
    Findings.new(
      :warning,
      "#{mod}'s terminate/2 does work that a supervisor shutdown will skip",
      "#{mod} does not trap exits, so a #{behaviour} shutdown from its supervisor " <>
        "kills it outright and terminate/2 never runs. #{via} calls #{api}, which " <>
        "the effect model cannot classify — so this cannot say WHAT is skipped, only " <>
        "that terminate/2 does more than log and none of it will happen on the normal " <>
        "stop path. If that call releases a lease, closes a session or flushes a " <>
        "buffer, it is silently not happening in production.",
      at: Findings.at_func("#{mod}:terminate/2"),
      at_label: "a supervisor shutdown skips this",
      help: [
        "add `Process.flag(:trap_exit, true)` in init/1, or move the cleanup " <>
          "somewhere it will run"
      ]
    )
  end

  def finding(:teardown_touches_sibling, [
        mod,
        sibling,
        "handler",
        "stop",
        via,
        sup,
        handler,
        site,
        sup_site
      ]) do
    Findings.new(
      :warning,
      "A callback stops a sibling the supervisor owns",
      "#{handler} stops #{sibling}#{through(via, mod)}, and both #{mod} and " <>
        "#{sibling} are children of #{sup}. The supervisor owns that child: a " <>
        "permanent one comes straight back, and during shutdown it may already " <>
        "be gone, so the stop exits with :noproc in #{mod}.",
      at: Findings.at_site_in_func(site, handler, mod),
      at_label: "stops the sibling from this callback",
      related:
        [Findings.related("the sibling's stop API", Findings.at_func(via))] ++
          placed_by(sup, sup_site),
      help: [
        "ask the supervisor: `Supervisor.terminate_child/2` (and `delete_child/2`)",
        "or send the sibling a message and let it stop itself"
      ]
    )
  end

  # Two of the supervisor's own sequences stop the sibling before they
  # terminate mod: its shutdown, in reverse start order ("call", a sibling
  # started after mod), and its rest_for_one or one_for_all restart
  # ("call_restart", a sibling started before mod whose crash is why mod
  # is terminated). When the listing or strategy does not settle which
  # applies ("call_unordered"), the finding is reported a step less
  # surely, saying so.
  def finding(:teardown_touches_sibling, [
        mod,
        sibling,
        "terminate",
        kind,
        via,
        sup,
        _handler,
        site,
        sup_site
      ])
      when kind in ["call", "call_restart", "call_unordered"] do
    {severity, why, label, fix} = sibling_order(kind, mod, sibling, sup)

    Findings.new(
      severity,
      "terminate/2 calls a sibling that may already be down",
      "#{mod}'s terminate/2 waits on #{sibling}#{through(via, mod)}, and both run " <>
        "under #{sup}. #{why}: the call exits with :noproc, so what it was for " <>
        "never happens, and terminate/2 crashes, skipping anything after it.",
      at: Findings.at_site_in_func(site, via, mod),
      at_label: label,
      related: placed_by(sup, sup_site, "both run under #{sup}, placed here"),
      help: ["wrap the call in `try ... catch :exit, _ -> :ok`, or make it a cast", fix]
    )
  end

  def finding(:foreign_dynamic_children, [mod, sup, via, site, sup_site]) do
    Findings.new(
      :warning,
      "children started under another tree outlive their owner",
      "#{via} starts children under #{sup}, a DynamicSupervisor #{mod} does not sit " <>
        "under. Their lifetime follows #{sup}'s tree, not #{mod}'s: when #{mod}'s tree " <>
        "shuts down they keep running — reconnecting, logging, calling into " <>
        "applications that have already stopped — and #{mod}'s terminate/2 does " <>
        "not stop them.",
      at: Findings.at_site_in_func(site, via, mod),
      at_label: "start_child onto a supervisor in another tree",
      related: placed_by(sup, sup_site),
      help: [
        "give #{mod} a terminate/2 (trapping exits) that terminates the children it started",
        "or start them under a DynamicSupervisor in #{mod}'s own tree"
      ]
    )
  end

  def finding(:cleanup_defect, [mod, behaviour, "truncated", category, api, via]) do
    Findings.new(
      :warning,
      "#{mod}'s terminate/2 does unbounded work inside the shutdown timeout",
      "#{via} calls #{api} — #{phrase(category)} — from #{mod}'s terminate/2. " <>
        "The module traps exits, so the callback is reached, but a #{behaviour} " <>
        "child gets only its shutdown timeout (5000ms unless the child spec says " <>
        "otherwise) before the supervisor brutal-kills it. A call with no bound of " <>
        "its own can exceed that, and the cleanup is truncated at whatever point it " <>
        "had reached — often worse than not starting.",
      at: Findings.at_func("#{mod}:terminate/2"),
      at_label: "unbounded work inside the shutdown timeout",
      help: ["bound the call, or raise the child's `shutdown` timeout to cover it"]
    )
  end

  def finding(:unhandled_exit_signal, [mod, "no_handler", witness]) do
    Findings.new(
      :warning,
      "trap_exit without an :EXIT handler",
      "#{mod} sets trap_exit but defines no handle_info({:EXIT, ...}, _) " <>
        "clause. Exit signals from linked processes arrive as plain mailbox " <>
        "messages and fall through to the default handle_info — a crash or a " <>
        "noisy log, exactly what trapping was meant to prevent.",
      at: Findings.at_func(witness),
      at_label: "traps exits here",
      help: ["add a `handle_info({:EXIT, pid, reason}, state)` clause"]
    )
  end

  def finding(:unhandled_exit_signal, [mod, "no_exit_clause", witness]) do
    Findings.new(
      :warning,
      "trap_exit without an {:EXIT, ...} clause",
      "#{mod} sets trap_exit and defines handle_info/2, but no clause " <>
        "matches {:EXIT, pid, reason} and none is a catch-all. A trapped " <>
        "exit arrives as an ordinary message, and once handle_info/2 is " <>
        "defined an unmatched message is a FunctionClauseError — the " <>
        "process dies on the very signal trapping was meant to absorb, " <>
        "the first time anything it linked to exits.",
      at: Findings.at_func(witness),
      at_label: "exits are trapped here",
      help: [
        "add a `handle_info({:EXIT, pid, reason}, state)` clause that " <>
          "decides what a linked exit means for this process, or a " <>
          "catch-all `handle_info(_msg, state)` if none are expected"
      ],
      related: [Findings.related("handle_info/2", Findings.at_mfa(mod, :handle_info, 2))]
    )
  end

  def finding(:kills_monitored_child, [mod, site, kill_site]) do
    Findings.new(
      :info,
      "#{mod} terminates a process it still monitors",
      "#{mod} monitors processes from its callbacks and also terminates " <>
        "them on purpose, without demonitoring first. The {:DOWN, ...} for a " <>
        "death this server caused is delivered like any other — into the " <>
        "clause written for crashes, which may restart, reconnect or log " <>
        "what was a deliberate stop.",
      at: Findings.at_site(kill_site, mod),
      at_label: "the monitored process is terminated here",
      help: [
        "call `Process.demonitor(ref, [:flush])` before terminating, and drop " <>
          "the entry from the bookkeeping in the same step"
      ],
      related: [Findings.related("monitor established", Findings.at_site(site, mod))]
    )
  end

  def finding(:permanent_child_stops_normally, [sup, child, reason, site, sup_site]) do
    Findings.new(
      :info,
      "Permanent child stops itself and is restarted",
      "#{child} returns {:stop, #{reason}, ...} from a callback, but " <>
        "#{sup} runs it as a :permanent child, and a supervisor restarts a " <>
        "permanent child whatever the exit reason. The process asks to go " <>
        "away and is started straight back; whatever the stop was meant to " <>
        "achieve — a graceful permdown, a drain-and-quit — is undone at " <>
        "once, and the restart counts toward the supervisor's intensity.",
      at: Findings.at_site(site, child),
      at_label: "this stop is followed by a restart",
      help: [
        "if the child is meant to stop on its own, give its spec " <>
          "`restart: :transient` (restarted only on abnormal exit) or " <>
          "`:temporary`; if it must always run, do not stop it from a callback"
      ],
      related: [
        Findings.related("child spec", Findings.at_site(sup_site, sup))
      ]
    )
  end

  # When the call to the sibling is in a helper, the path starts at a call
  # in terminate/2: the line a reader follows from the callback.
  @impl true
  def evidence(:cleanup_site, [_mod, _kind, api, via, site]) do
    Findings.related("calls #{api}", Findings.at_site_in_func(site, via))
  end

  def evidence(:terminate_path, [handler, _via, ""]) do
    Findings.related("terminate/2 reaches it from here", Findings.at_func(handler))
  end

  def evidence(:terminate_path, [handler, _via, call]) do
    Findings.related("terminate/2 reaches it from here", Findings.at_site_in_func(call, handler))
  end

  defp phrase("io"), do: "file I/O"
  defp phrase("network"), do: "network I/O"
  defp phrase("ets"), do: "a shared-table write"
  defp phrase("process"), do: "a process operation"
  defp phrase("port"), do: "a port or OS operation"
  defp phrase("node"), do: "a distribution operation"
  defp phrase(other), do: other

  # The witness is worth naming when it is not the callback itself: a
  # helper terminate/2 reaches, or an anonymous function inside it.
  defp through(via, mod) when via == mod <> ":terminate/2", do: ""
  defp through(via, _mod), do: " (through #{via})"

  defp sibling_order("call", mod, sibling, sup) do
    {:warning,
     "#{sibling} is started after #{mod}, and a supervisor stops its children in " <>
       "reverse start order, so when #{sup} shuts down #{sibling} has already exited " <>
       "by the time #{mod}'s terminate/2 runs", "synchronous call to a sibling that stops first",
     "or start #{sibling} before #{mod}, so a shutdown stops #{mod} first"}
  end

  defp sibling_order("call_restart", mod, sibling, sup) do
    {:warning,
     "#{sibling} is started before #{mod}, and #{sup} restarts the children started " <>
       "after one that crashes (rest_for_one or one_for_all), so when #{sibling} " <>
       "crashes #{sup} terminates #{mod} too, and its terminate/2 calls the sibling " <>
       "that just exited", "synchronous call to the sibling whose crash stops this process",
     "or let terminate/2 finish without #{sibling}: it runs here because #{sibling} died"}
  end

  defp sibling_order("call_unordered", mod, sibling, sup) do
    {:info,
     "#{sup}'s child list or restart strategy does not settle whether #{sibling} is " <>
       "still up: a supervisor stops a sibling started after #{mod} before #{mod}, and " <>
       "under rest_for_one or one_for_all an earlier sibling's crash is what terminates " <>
       "#{mod}",
     "synchronous call to a sibling during shutdown (start order or strategy unknown)",
     "or order the children so #{sibling} outlives #{mod}'s terminate/2"}
  end

  defp placed_by(sup, sup_site),
    do: placed_by(sup, sup_site, "both are children of #{sup}, placed here")

  # A terminate/2 row's two may sit in branches under sup rather than be
  # its children: sup is where their branches meet.
  defp placed_by(_sup, "", _label), do: []

  defp placed_by(sup, sup_site, label),
    do: [Findings.related(label, Findings.at_site(sup_site, sup))]
end
