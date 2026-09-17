defmodule Argus.Analyses.Supervision do
  @moduledoc """
  Supervision tree analysis.

  Detects anti-patterns in supervision tree structure: permanent
  processes depending on transient or temporary siblings (which their
  restart policy can leave permanently dead), and children started in
  the wrong order relative to their dependencies. Cross-branch coupling
  under one_for_one is the `one_for_one_coupling` analysis's job — the
  two do not overlap.

  Requires the supervision and OTP domain extractors for layer 2 facts
  about supervisor children, restart strategies, and behaviour implementations.

  ## Output relations

  - `suspect_nonpermanent_dependency(sup, permanent, sibling, restart, sup_site, witness)` — permanent child depends on a transient or temporary sibling.
  - `permanent_child_stops_normally(sup, child, reason, site, sup_site)` — a
    permanent child returns `{:stop, :normal | :shutdown, ...}` and is
    restarted by its supervisor.
  - `rest_for_one_orphaned_children(sup, owner, holder, owner_pos, holder_pos, site, confidence)`
    — under rest_for_one a later child starts processes inside an
    earlier one, which survives the owner's restart.
  - `wrong_start_order(sup, child, dep, child_pos, dep_pos, sup_site, witness)` — child starts before its dependency.

  ## Finding severities

  Both relations are `:warning`: each is a structural hazard that
  bites during crash/restart windows rather than a guaranteed failure in
  steady state.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :supervision

  @impl true
  def description, do: "supervision tree structure and anti-patterns"

  @impl true
  def rules_file, do: "analyses/supervision.dl"

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
      # See sync_call_in_init: `sync_call` is partly derived by
      # clientlib/interprocedural.dl, which needs call_arg and
      # call_arg_forward to resolve a target forwarded through a wrapper.
      Argus.Extractors.CallArgs
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :supervisor_registered_as_worker,
        fields: [
          {:sup, :symbol, "the parent supervisor"},
          {:child, :symbol, "the child, which is itself a supervisor"},
          {:position, :number, "the child's start position"}
        ],
        key: [:sup, :child],
        doc: "A supervisor child spec that explicitly says type: :worker."
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
        name: :consumer_supervisor_permanent_child,
        fields: [
          {:sup, :symbol, "the ConsumerSupervisor"},
          {:child, :symbol, "the child template module"},
          {:sup_site, :symbol, "where the template is declared"}
        ],
        doc: "A ConsumerSupervisor child template with restart :permanent."
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
      }
    ]
  end

  # These defects live in the supervisor's composition — strategy and
  # child order — so findings anchor at the tree definition (where the
  # fix goes) and the dependency's call path becomes labelled evidence.
  @impl true
  def finding(:supervisor_registered_as_worker, [sup, child, _position]) do
    Findings.new(
      :error,
      "#{sup} registers #{child} as a worker, but it is a supervisor",
      "#{child} implements the Supervisor behaviour, and #{sup}'s child spec " <>
        "explicitly says type: :worker. " <>
        "OTP requires a supervisor child to be registered with " <>
        "type: :supervisor and shutdown: :infinity. The type is what tells the " <>
        "parent to give the child unlimited time to bring its own subtree " <>
        "down; a worker gets a finite shutdown, so it is killed part-way " <>
        "through unlinking its children and the grandchildren are orphaned " <>
        "rather than terminated. They keep running, holding whatever they " <>
        "held, with no supervisor above them. " <>
        "RabbitMQ shipped exactly this (e40387e4): three modules carrying the " <>
        "supervisor behaviour registered through a helper that builds worker " <>
        "specs. " <>
        "Note this is reported only for specs that SAY worker — the " <>
        "{Module, args} shorthand states no type and child_spec/1 gets it " <>
        "right, so those are not findings.",
      at: Findings.at_module(child),
      at_label: "this module is a supervisor",
      help: [
        "register `#{child}` with `type: :supervisor, shutdown: :infinity` — " <>
          "or use the `{#{child}, args}` shorthand and let its `child_spec/1` " <>
          "declare the type"
      ],
      related: [Findings.related("parent supervisor", Findings.at_module(sup))]
    )
  end

  @impl true
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

  def finding(:consumer_supervisor_permanent_child, [sup, child, sup_site]) do
    Findings.new(
      :warning,
      "ConsumerSupervisor template restarts finished children",
      "#{sup} is a ConsumerSupervisor and its child template #{child} is " <>
        ":permanent. Each child handles one event and exits :normal when done; a " <>
        "permanent template starts it straight back, where it fails again, " <>
        "consuming demand and counting toward the restart intensity until the " <>
        "supervisor itself gives up.",
      at: Findings.at_site(sup_site, sup),
      at_label: "child template declared here",
      help: ["give the template `restart: :temporary` (or `:transient`)"]
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
end
