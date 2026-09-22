defmodule Argus.Analyses.Structure do
  @moduledoc """
  A child spec, registration or tree shape that is wrong on its own.

  - `supervisor_registered_as_worker(sup, child, position)` — a child
    spec that explicitly says `type: :worker` for a module that is a
    supervisor, so it gets a finite shutdown and its grandchildren are
    orphaned rather than terminated.
  - `consumer_supervisor_permanent_child(sup, child, sup_site)` — a
    ConsumerSupervisor template with `restart: :permanent` restarts every
    finished child.
  - `duplicate_process_name(name, mod1, mod2, site1, site2)` — one name
    registered by two modules; at most one can run.
  - `global_register_risk(func, name, site)` — `:global.register_name/2`
    with no conflict resolver: after a netsplit heals, one of the two
    holders is killed at random.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :structure

  @impl true
  def description, do: "child specs, registrations and tree shapes that are wrong on their own"

  @impl true
  def rules_file, do: "analyses/structure.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Supervision,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.ProcessRegistry
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
        name: :consumer_supervisor_permanent_child,
        fields: [
          {:sup, :symbol, "the ConsumerSupervisor"},
          {:child, :symbol, "the child template module"},
          {:sup_site, :symbol, "where the template is declared"}
        ],
        doc: "A ConsumerSupervisor child template with restart :permanent."
      },
      %{
        name: :duplicate_process_name,
        fields: [
          {:name, :symbol, "registered name"},
          {:mod1, :symbol, "first registering module"},
          {:mod2, :symbol, "second registering module"},
          {:site1, :symbol, "registration instruction in mod1"},
          {:site2, :symbol, "registration instruction in mod2"}
        ],
        key: [:name, :mod1, :mod2],
        doc: "Same atom name registered by multiple modules."
      },
      %{
        name: :global_register_risk,
        fields: [
          {:func, :symbol, "function"},
          {:name, :symbol, "global name"},
          {:site, :symbol, "instruction ID of the registration"}
        ],
        key: [:func, :name],
        doc: "global.register_name without conflict resolution callback."
      }
    ]
  end

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

  def finding(:duplicate_process_name, [name, mod1, mod2, site1, site2]) do
    Findings.new(
      :error,
      "Process name registered by two modules",
      "Both #{mod1} and #{mod2} register the name #{name}. Name registration " <>
        "is exclusive — whichever process registers second crashes with " <>
        "ArgumentError (or its start_link returns {:error, {:already_started, " <>
        "pid}}). At most one of these can ever run at a time.",
      at: Findings.at_site(site1, mod1),
      related: [Findings.related("other registrant", Findings.at_site(site2, mod2))]
    )
  end

  def finding(:global_register_risk, [func, name, site]) do
    Findings.new(
      :warning,
      ":global registration without conflict resolution",
      "#{func} registers #{name} via :global without a resolve function. " <>
        "After a netsplit heals, both partitions hold the name and the " <>
        "default resolution kills one of the processes at random — state " <>
        "loss decided by a coin flip.",
      at: Findings.at_instr(site)
    )
  end
end
