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
  - `registry_race(mod, func, lookup_api, create_api, key, check, act)` —
    a lookup of a name decides a start, registration or unregistration of
    the same name, the losing outcome is taken nowhere, and more than one
    process can run the function where the two meet: the lookup-then-start
    race, and its release twin, lookup-then-unregister. The lookup and the
    act may sit in helpers `func` calls, or reach each other through a
    parameter or a loop (`clientlib/check_then_act.dl`).
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :structure

  @impl true
  def description,
    do:
      "child specs, registrations and tree shapes that are wrong on their own, " <>
        "and lookup-then-start races on a process name"

  @impl true
  def rules_file, do: "analyses/structure.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Supervision,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.ProcessRegistry,
      Argus.Extractors.ErrorHandling,
      Argus.Extractors.Dependence,
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
        name: :registry_race,
        fields: [
          {:mod, :symbol, "the module"},
          {:func, :symbol, "the function where the lookup's result meets the act"},
          {:lookup_api, :symbol, "whereis | registry_lookup | registered"},
          {:create_api, :symbol,
           "register | start_link | start | start_via | registry_register | start_child | unregister"},
          {:key_source, :symbol, "literal | param | field | local | dynamic | any"},
          {:key, :symbol,
           "the name, as func identifies it: the literal, a parameter's position, a field's key"},
          {:check, :symbol, "instruction ID of the lookup"},
          {:act, :symbol, "instruction ID of the start or registration"}
        ],
        key: [:func, :key],
        doc:
          "A lookup decides a start or release of the same name, and a second caller can act in the window."
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
      at_label: "registers #{name} here",
      related: [Findings.related("other registrant", Findings.at_site(site2, mod2))],
      help: ["give each module its own name, or start only one of them"]
    )
  end

  def finding(:registry_race, [mod, func, lookup_api, "unregister", key_source, key, check, act]) do
    Findings.new(
      :warning,
      "Lookup-then-unregister race on a process name",
      "#{func} asks whether #{describe_key(key_source, key)} is registered " <>
        "(#{lookup(lookup_api)}#{Findings.elsewhere(check, func)}) and unregisters it" <>
        "#{Findings.elsewhere(act, func)} when the answer is yes. The name can go " <>
        "between the two — its process exits and is unregistered with it, or another " <>
        "caller unregisters it first — and unregister/1 then raises ArgumentError, " <>
        "which nothing here rescues.",
      at: Findings.at_site(act, mod),
      at_label: "this unregister runs after the lookup has gone stale",
      related: [Findings.related("the lookup it depends on", Findings.at_site(check, mod))],
      help: [
        "unregister unconditionally and rescue `ArgumentError` (`catch error:badarg` in Erlang)",
        "or leave the name to the process holding it: a registered name goes when its process exits"
      ]
    )
  end

  def finding(:registry_race, [mod, func, lookup_api, create_api, key_source, key, check, act]) do
    Findings.new(
      :warning,
      "Lookup-then-start race on a process name",
      "#{func} asks whether #{describe_key(key_source, key)} is registered " <>
        "(#{lookup(lookup_api)}#{Findings.elsewhere(check, func)}) and " <>
        "#{create(create_api)}#{Findings.elsewhere(act, func)} when the answer is no. " <>
        "Nothing holds the name between the two: a second caller that asks in the same " <>
        "window gets the same answer, and one of the two starts loses — " <>
        "{:error, {:already_started, pid}} from a start, an ArgumentError from " <>
        "register/2 — which is taken nowhere.",
      at: Findings.at_site(act, mod),
      at_label: "this start runs after the lookup has gone stale",
      related: [Findings.related("the lookup it depends on", Findings.at_site(check, mod))],
      help: [
        "make the start the check: start unconditionally and treat " <>
          "`{:error, {:already_started, pid}}` as `{:ok, pid}`",
        "for a Registry, `Registry.register/3` and its `{:error, {:already_registered, pid}}` " <>
          "replace the lookup",
        "if the decision must span both, serialise it through one process — the owner, or " <>
          "`:global.trans/2`"
      ]
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
      at: Findings.at_instr(site),
      at_label: "registered via :global without a resolver",
      help: [
        "pass a resolve function (`:global.register_name/3`) that picks the survivor deliberately"
      ]
    )
  end

  # The name as the function sees it. A parameter's key is its position,
  # which reads as a number only to the facts.
  defp describe_key("literal", key) when key != "", do: key
  defp describe_key("field", key) when key != "", do: "the name held under #{key}"

  defp describe_key("param", position) do
    case Integer.parse(position) do
      {n, ""} when n in 0..9 ->
        ordinal = Enum.at(~w(first second third fourth fifth sixth seventh eighth ninth tenth), n)
        "the name in its #{ordinal} argument"

      _ ->
        "the name"
    end
  end

  defp describe_key(_local_dynamic_or_any, _key), do: "the name"

  defp lookup("whereis"), do: "whereis"
  defp lookup("registry_lookup"), do: "Registry.lookup"
  defp lookup("registered"), do: "Process.registered"
  defp lookup(other), do: other

  defp create("register"), do: "registers it"
  defp create("registry_register"), do: "registers it in the Registry"
  defp create("start_child"), do: "starts a child"
  defp create("start_via"), do: "starts a process under it"
  defp create(_start), do: "starts a process named by it"
end
