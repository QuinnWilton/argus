defmodule Argus.Analyses.OneForOneCoupling do
  @moduledoc """
  One-for-one coupling analysis.

  Detects cross-branch coupling under one_for_one supervisors: when one child
  calls another's API, a crash of the callee won't restart the caller, leaving
  it with a stale reference. Pairs linked to each other (directly or through
  the supervisor hierarchy) are excluded — the exit propagates and both
  restart together, so the stale-reference hazard is already mitigated.

  Requires the supervision and OTP domain extractors for layer 2 facts
  about supervisor children and inter-process communication.

  ## Output relations

  - `one_for_one_coupling(sup, caller_mod, callee_mod, sup_site, witness, site, kind)` — cross-branch coupling under one_for_one; `site` is the coupling call instruction when known, else the witness function; `kind` is `call` or `cast`.

  ## Finding severities

  `:warning`: restart isolation hazards surface as stale references and
  failed calls during crash windows, not as immediate failures.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :one_for_one_coupling

  @impl true
  def description, do: "cross-branch coupling under one_for_one supervisors"

  @impl true
  def rules_file, do: "analyses/one_for_one_coupling.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.CallbackTag,
      Argus.Extractors.Supervision,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      # See sync_call_in_init: `sync_call` is partly derived by
      # clientlib/interprocedural.dl, which needs call_arg and
      # call_arg_forward to resolve a target forwarded through a wrapper.
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
      }
    ]
  end

  # The defect is the supervisor's composition, not the caller's code —
  # the same call is fine under rest_for_one — so the finding anchors at
  # the tree definition (where the fix goes) and the coupling call site
  # becomes labelled evidence.
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
end
