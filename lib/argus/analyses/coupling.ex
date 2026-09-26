defmodule Argus.Analyses.Coupling do
  @moduledoc """
  Two owners of one relationship across supervisor branches.

  A supervisor restarts what it owns: the restarted child starts afresh,
  without what a sibling registered with it, and a sibling that cached
  its pid keeps a dead one. The sibling is not restarted with it. The
  strategy decides who survives whom.

  - `sibling_dependency(sup, caller, callee, reason, detail, sup_site,
    witness, site, basis, permille)` — a child depends on a sibling that a restart leaves
    stale. `reason` is `restart_isolation` (two branches of a
    `one_for_one` supervisor, the caller's once code registering
    something the sibling keeps: `detail` says how it keeps it,
    clientlib/restart_state.dl and docs/design/restart-state.md),
    `restart_policy` (a permanent child depends on a transient or
    temporary sibling that may never come back; `detail` is that policy)
    or `cached_pid` (`init/1` looks the sibling up by name under
    `one_for_one` and the handlers call the cached pid).
  - `rest_for_one_orphaned_children(sup, owner, holder, ...)` — under
    `rest_for_one` a later child starts processes inside an earlier one;
    the owner's restart leaves them running.
  - `dual_restart_authority(mod, sup, child, via, start_site,
    monitor_site, handler)` — a process starts a
    child under a DynamicSupervisor, monitors it and restarts it from its
    `:DOWN` handler while the supervisor restarts it too.

  The defect is the tree's composition, so findings anchor at the tree
  definition where they can, and the dependency's call path is labelled
  evidence.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :coupling

  @impl true
  def description, do: "two owners of one relationship across supervisor branches"

  @impl true
  def rules_file, do: "analyses/coupling.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Monitor,
      Argus.Extractors.ProcessRegistry,
      Argus.Extractors.Supervision,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.Reply,
      # `sync_call` is partly derived through call_arg and call_arg_forward:
      # a target forwarded through a wrapper.
      Argus.Extractors.CallArgs,
      # A call whose target is a pid resolves through process points-to
      # (clientlib/processes.dl, in the points-to stage): where the pid was
      # started, and names.
      Argus.Extractors.PidFlow,
      # A gen_statem's state functions and data (clientlib/process_statem.dl,
      # and processes.dl in the points-to stage).
      Argus.Extractors.GenStatem,
      # What a sibling's handler keeps of a request (clientlib/restart_state.dl):
      # the clause it enters (clause_call), its ETS writes, the state it
      # returns (returned_update, returns_call) and the calls the effect
      # model knows or does not (impure_call, unknown_call).
      Argus.Extractors.ClauseCall,
      Argus.Extractors.ETS,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.Purity,
      # Which code a library's macro wrote (library_written): an export no
      # program code calls is code that runs again unless a library wrote
      # it (clientlib/runs.dl, what once code's clauses are told against).
      Argus.Extractors.Generated,
      # Where a handler runs only while a field of its state says it has
      # not yet, and what the returns set the field to (state_gate,
      # gate_closed, state_return): a site that runs once by the state
      # (clientlib/runs.dl, gated_once_site).
      Argus.Extractors.StateGate,
      Argus.Extractors.Tooling
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :sibling_dependency,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:caller, :symbol, "the child that depends on its sibling"},
          {:callee, :symbol, "the sibling depended on (module or registered name)"},
          {:reason, :symbol,
           "why the dependency goes stale: restart_isolation | restart_policy | cached_pid"},
          {:detail, :symbol,
           "for restart_isolation how the sibling keeps what the child registers (table | monitor | state | dict | handed), " <>
             "the sibling's restart policy for restart_policy, empty for cached_pid"},
          {:sup_site, :symbol, "instruction ID of the tree definition"},
          {:witness, :symbol,
           "restart_isolation: the sibling's instruction or function that keeps it; " <>
             "otherwise the function in the caller carrying the dependency"},
          {:site, :symbol,
           "restart_isolation: the child's request, or its call into the sibling's module that makes it; " <>
             "otherwise the witness function ID"},
          {:basis, :symbol,
           "resolved | inferred | doubted — how the dependency (restart_isolation: the keeping) was established, see coupling.dl"},
          {:permille, :number,
           "for a doubted row, the prior's probability that the sibling talks to a process"}
        ],
        key: [:sup, :caller, :callee, :reason],
        doc: "A child depends on a sibling that a restart leaves stale."
      },
      %{
        name: :rest_for_one_orphaned_children,
        fields: [
          {:sup, :symbol, "the rest_for_one supervisor"},
          {:owner, :symbol, "the later child that starts processes"},
          {:holder, :symbol, "the earlier child they are started under"},
          {:owner_pos, :number, "owner's branch position"},
          {:holder_pos, :number, "holder's position"},
          {:site, :symbol, "the start_child / async_nolink call in the owner"},
          {:basis, :symbol,
           "resolved when the call names the holder, inferred otherwise (sibling_dependency's words)"}
        ],
        key: [:sup, :owner, :holder],
        doc:
          "Under rest_for_one a later child starts processes inside an earlier one; " <>
            "the owner's restart leaves them running."
      },
      %{
        name: :dual_restart_authority,
        fields: [
          {:mod, :symbol, "the module that starts, monitors and restarts the child"},
          {:sup, :symbol, "the DynamicSupervisor that also restarts it"},
          {:child, :symbol, "the child module"},
          {:via, :symbol, "function that starts and monitors it"},
          {:start_site, :symbol, "the start_child call, else empty"},
          {:monitor_site, :symbol, "the monitor call"},
          {:handler, :symbol, "the :DOWN handler that starts it again"}
        ],
        key: [:mod, :sup, :child],
        doc: "A supervisor and a monitoring process both restart the same child."
      },
      Argus.Findings.Tooling.relation()
    ]
  end

  @impl true
  def finding(:sibling_dependency, [
        sup,
        caller_mod,
        callee_mod,
        "restart_isolation",
        how,
        sup_site,
        store,
        site,
        basis,
        _p
      ]) do
    Findings.new(
      if(basis == "inferred", do: :info, else: :warning),
      "Coupled children under one_for_one",
      "#{caller_mod} registers with #{callee_mod} when it starts, and " <>
        "#{kept(how, callee_mod)}. Both are children of the one_for_one " <>
        "supervisor #{sup}, which restarts either alone. When #{callee_mod} " <>
        "restarts, its init/1 starts it afresh without what #{caller_mod} " <>
        "put there, and #{caller_mod}, which is not restarted with it, " <>
        "never registers again. When #{caller_mod} restarts, it registers " <>
        "a second time beside what its old process left.",
      at: Findings.at_site(sup_site, sup),
      at_label: "supervision tree defined here",
      help:
        [
          "put the pair under `rest_for_one` with `#{callee_mod}` started " <>
            "before `#{caller_mod}`, or under `one_for_all`: a `#{callee_mod}` " <>
            "restart then restarts `#{caller_mod}`, which registers again",
          "or have `#{caller_mod}` monitor `#{callee_mod}` and register again " <>
            "when it goes down"
        ] ++ inferred_keeping(callee_mod, basis),
      related: [
        Findings.related("registers with the sibling here", Findings.at_site(site, caller_mod)),
        Findings.related(kept_label(how), Findings.at_site(store, callee_mod))
      ]
    )
  end

  def finding(:sibling_dependency, [
        sup,
        permanent,
        sibling,
        "restart_policy",
        restart,
        sup_site,
        witness,
        _s,
        basis,
        p
      ]) do
    consequence =
      case restart do
        "temporary" ->
          "A temporary child is never restarted — not even after a crash —"

        _ ->
          "A transient child that stops normally is never restarted,"
      end

    Findings.new(
      :warning,
      "Permanent child depends on a #{restart} sibling",
      "#{permanent} is a permanent child of #{sup} but depends on its #{restart} " <>
        "sibling #{sibling}. #{consequence} so #{permanent} keeps running " <>
        "against a process that no longer exists.",
      at: Findings.at_site(sup_site, sup),
      at_label: "supervision tree defined here",
      help: [
        "make `#{sibling}` `:permanent` so it always comes back, or make " <>
          "`#{permanent}` tolerate its absence (monitor and re-resolve " <>
          "instead of assuming liveness)"
      ],
      related: [
        Findings.related("dependency call", Findings.at_func(witness)),
        Findings.related("#{restart} sibling", Findings.at_module(sibling))
      ]
    )
    |> doubt(sibling, basis, p)
  end

  def finding(:rest_for_one_orphaned_children, [sup, owner, holder, opos, hpos, site, basis]) do
    hedge =
      case basis do
        "resolved" ->
          ""

        _ ->
          " (inferred: the call's target is a runtime value and #{holder} is the only earlier #{holder} under #{sup})"
      end

    Findings.new(
      if(basis == "resolved", do: :warning, else: :info),
      "rest_for_one restarts the owner but not the processes it started",
      "#{owner} (position #{opos}) starts processes under #{holder} " <>
        "(position #{hpos}) of #{sup}, a rest_for_one supervisor#{hedge}. " <>
        "When #{owner} crashes, the supervisor restarts it and every " <>
        "later child, but #{holder} started earlier and survives — with " <>
        "the processes the old #{owner} started still running inside it. " <>
        "The new #{owner} knows nothing of them and starts its own: " <>
        "duplicated work, or a stale process holding a resource the " <>
        "replacement expects to own.",
      at: Findings.at_site(site, owner),
      at_label: "processes started here outlive their owner's restart",
      help: [
        "use `:one_for_all` so #{holder} restarts with #{owner}, or start " <>
          "#{holder} after #{owner} so rest_for_one takes it down too"
      ],
      related: [Findings.related("supervisor", Findings.at_module(sup))]
    )
  end

  def finding(:sibling_dependency, [
        sup,
        mod,
        name,
        "cached_pid",
        _,
        _sup_site,
        _init,
        _site,
        _b,
        _p
      ]) do
    Findings.new(
      :warning,
      "Sibling pid cached in init/1 under one_for_one",
      "#{mod}'s init/1 looks up #{name} and its handlers call a pid held in " <>
        "state. Both are children of #{sup}, a :one_for_one supervisor: when " <>
        "#{name} restarts, #{mod} does not, and the cached pid is a dead " <>
        "process — every call :noproc, every message lost.",
      at: Findings.at_mfa(mod, :init, 1),
      at_label: "looks the sibling up here",
      help: [
        "call the sibling by its registered name (or a :via tuple) instead of a cached pid",
        "or make the dependency explicit with :rest_for_one, #{name} first"
      ]
    )
  end

  def finding(:dual_restart_authority, [
        mod,
        sup_or_dynamic,
        child,
        via,
        start_site,
        monitor_site,
        handler
      ]) do
    sup = if sup_or_dynamic == "dynamic", do: "a DynamicSupervisor", else: sup_or_dynamic

    Findings.new(
      :warning,
      "Two restart authorities for the same child",
      "#{via} starts #{child} under #{sup} and monitors it, and #{mod}'s " <>
        ":DOWN handler starts it again — while the supervisor restarts it as well, " <>
        "as a permanent child. A child that stops on a semantic error is " <>
        "restarted by both: it crash-loops, exhausts the supervisor's restart " <>
        "intensity, and the escalation reaches the tree above.",
      at: Findings.at_site_in_func(start_site, via, mod),
      at_label: "started under the supervisor here",
      related: [
        Findings.related("monitored here", Findings.at_site(monitor_site, mod)),
        Findings.related("started again from this :DOWN handler", Findings.at_func(handler))
      ],
      help: [
        "start the child with `restart: :temporary` and let #{mod}'s :DOWN handler decide",
        "or drop the monitor and let the supervisor own the restarts"
      ]
    )
  end

  # How the keeper keeps what a sibling registers (coupling.dl's
  # restart_isolation `detail`, clientlib/restart_state.dl's `how`).
  defp kept("table", callee), do: "#{callee} keeps it as an ETS row"
  defp kept("monitor", callee), do: "#{callee} keeps a monitor or link for it"
  defp kept("state", callee), do: "#{callee} keeps it in its state"
  defp kept("dict", callee), do: "#{callee} keeps it in its process dictionary"

  defp kept("handed", callee),
    do: "#{callee} hands it to code outside the program, which may keep it"

  defp kept(_how, callee), do: "#{callee} keeps it"

  defp kept_label("handed"), do: "handed on here"
  defp kept_label(_how), do: "kept here"

  # What the keeper does with code outside the program is inferred: the
  # finding steps down a level (the rubric's evidence rule) and says so.
  defp inferred_keeping(callee, "inferred"),
    do: [
      "inferred: #{callee} hands the request to code outside the program; " <>
        "whether that code keeps it past #{callee}'s restart is not shown"
    ]

  defp inferred_keeping(_callee, _basis), do: []

  # A dependency the module-level clause inferred and a prior doubts: the
  # caller reaches the sibling, but the sibling's API, the model says,
  # does not message a process — a helper with a call in its start_link,
  # not a facade. A heuristic finding, sure to the degree the model was
  # that the sibling is *not* a process.
  defp doubt(attrs, callee, "doubted", p) do
    Findings.heuristic(
      attrs,
      1000 - String.to_integer(p),
      "#{callee}'s API does not talk to a process; the dependency was inferred " <>
        "from reaching it, not from a call"
    )
  end

  defp doubt(attrs, _callee, _basis, _p), do: attrs
end
