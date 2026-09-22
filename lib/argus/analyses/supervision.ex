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

  # These defects live in the supervisor's composition — strategy and
  # child order — so findings anchor at the tree definition (where the
  # fix goes) and the dependency's call path becomes labelled evidence.
  @impl true
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
end
