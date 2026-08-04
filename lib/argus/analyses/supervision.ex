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
      Argus.Extractors.Supervision,
      Argus.Extractors.OTP,
      Argus.Extractors.GenEvent,
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
      related: [
        Findings.related("dependency call", Findings.at_func(witness)),
        Findings.related("#{restart} sibling", Findings.at_module(sibling))
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
      related: [
        Findings.related("init-time call", Findings.at_func(witness)),
        Findings.related("dependency", Findings.at_module(dep))
      ]
    )
  end
end
