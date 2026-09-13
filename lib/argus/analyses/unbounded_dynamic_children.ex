defmodule Argus.Analyses.UnboundedDynamicChildren do
  @moduledoc """
  Processes an outside party can create without limit.

  `DynamicSupervisor` defaults to `max_children: :infinity`, and the default
  is what everyone uses — eight DynamicSupervisors across the projects swept
  for this, none of which set a cap. On its own that is fine: most dynamic
  supervisors are driven by trusted callers.

  The finding is the pairing, and it is a question about the call graph
  rather than about any one line: **can `start_child` be reached from a
  request handler?** If it can, an unauthenticated request creates a
  process and nothing bounds how many. Each costs a PID, a mailbox and a
  heap, and the node dies of memory exhaustion rather than of anything that
  looks like an attack.

  No single line is wrong, which is why reading the supervisor or the
  handler alone shows nothing.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :unbounded_dynamic_children

  @impl true
  def description, do: "unbounded process creation reachable from a request"

  @impl true
  def rules_file, do: "analyses/unbounded_dynamic_children.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Supervision,
      Argus.Extractors.OTP,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.Endpoint
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :unbounded_children_from_request,
        fields: [
          {:sup, :symbol, "the uncapped DynamicSupervisor"},
          {:child, :symbol, "the module being started"},
          {:via, :symbol, "the function calling start_child"},
          {:kind, :symbol, "the entry surface"}
        ],
        key: [:sup, :child],
        doc: "start_child on an uncapped DynamicSupervisor, reachable from a request."
      }
    ]
  end

  @impl true
  def finding(:unbounded_children_from_request, [sup, child, via, kind]) do
    Findings.new(
      :error,
      "#{sup} starts #{child} without limit, on request",
      "#{via} calls DynamicSupervisor.start_child/2 against #{sup}, and #{via} " <>
        "is reachable from a #{kind} entry point. #{sup} sets no max_children, " <>
        "so it takes the DynamicSupervisor default of :infinity. " <>
        "That makes the number of live #{child} processes a function of how many " <>
        "requests arrive, with no ceiling. Each costs a PID, a mailbox and a " <>
        "heap, so the node runs out of memory — and it does so looking like " <>
        "ordinary load rather than like an attack. " <>
        "Nothing here is wrong on its own line, which is why the supervisor and " <>
        "the handler each read fine in isolation. " <>
        "Set max_children on #{sup}, and decide what start_child returning " <>
        "{:error, :max_children} should mean for the caller — that error is the " <>
        "point, because refusing one request is what stops it becoming an " <>
        "outage for every request.",
      at: Findings.at_func(via),
      related: [Findings.related("supervisor", Findings.at_module(sup))]
    )
  end
end
