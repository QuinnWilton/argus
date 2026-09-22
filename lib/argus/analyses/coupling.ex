defmodule Argus.Analyses.Coupling do
  @moduledoc """
  Two owners of one relationship across supervisor branches.

  A supervisor restarts what it owns; a sibling holding a pid, a monitor
  or a cached reply of the restarted child is not restarted with it and
  keeps a stale reference. The strategy decides who survives whom.

  - `one_for_one_coupling(sup, caller, callee, sup_site, witness, site,
    kind)` — two children on different branches of a `one_for_one`
    supervisor, one depending on the other; `kind` is `call` when the
    caller waits on the sibling anywhere, `cast` when every path is
    one-way.
  - `suspect_nonpermanent_dependency(sup, permanent, sibling, restart,
    sup_site, witness)` — a permanent child depends on a transient or
    temporary sibling that may never come back.
  - `cached_sibling_pid(mod, name, sup)` — `init/1` looks a sibling up by
    name under `one_for_one` and the handlers call the cached pid.
  - `rest_for_one_orphaned_children(sup, owner, holder, ...)` — under
    `rest_for_one` a later child starts processes inside an earlier one;
    the owner's restart leaves them running.
  - `dual_restart_authority(mod, sup, child, via)` — a process starts a
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
      Argus.Extractors.CallArgs
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :one_for_one_coupling,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:caller_mod, :symbol, "calling child module"},
          {:callee_mod, :symbol, "called child module"},
          {:sup_site, :symbol, "instruction ID of the tree definition"},
          {:witness, :symbol, "function in caller_mod carrying the coupling"},
          {:site, :symbol, "instruction ID of the coupling call, or the witness function ID"},
          {:kind, :symbol, "call when the caller waits on the sibling anywhere, else cast"}
        ],
        key: [:sup, :caller_mod, :callee_mod],
        doc: "Cross-branch coupling under a one_for_one supervisor."
      },
      %{
        name: :suspect_nonpermanent_dependency,
        fields: [
          {:sup, :symbol, "supervisor module"},
          {:permanent, :symbol, "permanent child module"},
          {:sibling, :symbol, "depended-on sibling module"},
          {:restart, :symbol, "the sibling's restart policy: transient | temporary"},
          {:sup_site, :symbol, "instruction ID of the tree definition"},
          {:witness, :symbol, "function in the permanent child carrying the dependency"}
        ],
        key: [:sup, :permanent, :sibling],
        doc: "Permanent child depends on a transient or temporary sibling."
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
          {:confidence, :symbol, "named when the call names the holder, inferred otherwise"}
        ],
        key: [:sup, :owner, :holder],
        doc:
          "Under rest_for_one a later child starts processes inside an earlier one; " <>
            "the owner's restart leaves them running."
      },
      %{
        name: :cached_sibling_pid,
        fields: [
          {:mod, :symbol, "the module caching the pid"},
          {:name, :symbol, "the sibling looked up"},
          {:sup, :symbol, "their one_for_one supervisor"}
        ],
        doc: "init/1 caches a sibling's pid that a one_for_one restart makes stale."
      },
      %{
        name: :dual_restart_authority,
        fields: [
          {:mod, :symbol, "the module that starts, monitors and restarts the child"},
          {:sup, :symbol, "the DynamicSupervisor that also restarts it"},
          {:child, :symbol, "the child module"},
          {:via, :symbol, "function that starts and monitors it"}
        ],
        key: [:mod, :sup, :child],
        doc: "A supervisor and a monitoring process both restart the same child."
      }
    ]
  end

  @impl true
  def finding(:one_for_one_coupling, [sup, caller_mod, callee_mod, sup_site, _w, site, "cast"]) do
    Findings.new(
      :info,
      "One-way coupling under one_for_one",
      "#{caller_mod} sends casts to #{callee_mod}, and both are children of " <>
        "the one_for_one supervisor #{sup}. Nothing is awaited, so a " <>
        "#{callee_mod} restart is harmless unless #{caller_mod} caches its " <>
        "pid or state by some other route; the shape is worth knowing about, " <>
        "not fixing.",
      at: Findings.at_site(sup_site, sup),
      at_label: "supervision tree defined here",
      help: [
        "if `#{caller_mod}` ever holds a pid or monitor of `#{callee_mod}`, " <>
          "move the pair under `rest_for_one` with `#{callee_mod}` first"
      ],
      related: [
        Findings.related("coupling cast", Findings.at_site(site, caller_mod)),
        Findings.related("called sibling", Findings.at_module(callee_mod))
      ]
    )
  end

  def finding(:one_for_one_coupling, [sup, caller_mod, callee_mod, sup_site, _w, site, "call"]) do
    Findings.new(
      :warning,
      "Coupled children under one_for_one",
      "#{caller_mod} calls #{callee_mod}, but both are children of the " <>
        "one_for_one supervisor #{sup}. When #{callee_mod} crashes and " <>
        "restarts, #{caller_mod} is not restarted with it and may keep a " <>
        "stale pid, monitor, or cached reply it holds.",
      at: Findings.at_site(sup_site, sup),
      at_label: "supervision tree defined here",
      help: [
        "restart-coupled siblings belong under `rest_for_one`, with " <>
          "`#{callee_mod}` started before `#{caller_mod}` — a `#{callee_mod}` " <>
          "restart then restarts `#{caller_mod}` too",
        "alternatively, have `#{caller_mod}` monitor `#{callee_mod}` and " <>
          "re-resolve it on every use instead of caching state across crashes"
      ],
      related: [
        Findings.related("coupling call", Findings.at_site(site, caller_mod)),
        Findings.related("called sibling", Findings.at_module(callee_mod))
      ]
    )
  end

  def finding(:suspect_nonpermanent_dependency, [
        sup,
        permanent,
        sibling,
        restart,
        sup_site,
        witness
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
  end

  def finding(:rest_for_one_orphaned_children, [sup, owner, holder, opos, hpos, site, conf]) do
    hedge =
      case conf do
        "named" ->
          ""

        _ ->
          " (inferred: the call's target is a runtime value and #{holder} is the only earlier #{holder} under #{sup})"
      end

    Findings.new(
      if(conf == "named", do: :warning, else: :info),
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

  def finding(:cached_sibling_pid, [mod, name, sup]) do
    Findings.new(
      :info,
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

  def finding(:dual_restart_authority, [mod, sup_or_dynamic, child, via]) do
    sup = if sup_or_dynamic == "dynamic", do: "a DynamicSupervisor", else: sup_or_dynamic

    Findings.new(
      :warning,
      "Two restart authorities for the same child",
      "#{via} starts #{child} under #{sup} and monitors it, and #{mod}'s " <>
        ":DOWN handler starts it again — while the supervisor restarts it as well, " <>
        "as a permanent child. A child that stops on a semantic error is " <>
        "restarted by both: it crash-loops, exhausts the supervisor's restart " <>
        "intensity, and the escalation reaches the tree above.",
      at: Findings.at_func(via),
      at_label: "started and monitored here",
      help: [
        "start the child with `restart: :temporary` and let #{mod}'s :DOWN handler decide",
        "or drop the monitor and let the supervisor own the restarts"
      ]
    )
  end
end
