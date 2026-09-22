defmodule Argus.Analyses.UnsafeInput do
  @moduledoc """
  Attacker-shaped data reaching a sink.

  Three sinks matter on the BEAM: atom creation (the atom table is
  fixed-size and never collected), deserialization (`binary_to_term`
  materializes funs, ports and references) and code execution. Each is
  reported once, with how exposed it is:

  - `sink_reachable(id, func, api, sink, entry, kind, proximity)` — the
    sink is reachable from a request-handling callback (a Plug, a
    LiveView, a Channel, an Oban job, a Broadway pipeline). Proximity is
    the triage signal: `direct` means the sink is in the callback itself,
    operating on the request; `adjacent` one call away; `transitive`
    anywhere else in the callback's cone, a path rather than a proven
    flow.
  - `sink_without_request_path(id, func, api, sink)` — no request reaches
    it: atom creation and code execution reachable from an exported
    function, and every deserialization without `:safe`.
  - `sink_endpoint(sink, verb, path, plug)` — the HTTP route a sink is
    reachable from, when the router literal names one.
  - `unbounded_children_from_request(sup, child, via, kind)` —
    `start_child` on an uncapped DynamicSupervisor, reachable from a
    request: processes an outside party can create without limit.

  Severity follows proximity, calibrated against hand-verified findings:
  every direct finding in the corpus was real (livebook's `tag`, taken
  straight from the client payload), adjacent was mixed, and every
  transitive hit sourced its data from storage rather than the request.
  A sink no request reaches keeps the severities the sinks carried when
  they were reported by export reachability alone: deserialization is an
  error, code execution an error, atom creation a warning.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :unsafe_input

  @impl true
  def description,
    do: "atom exhaustion, unsafe deserialization and code execution reachable from a request"

  @impl true
  def rules_file, do: "analyses/unsafe_input.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ApiCalls,
      Argus.Extractors.OTP,
      Argus.Extractors.Router,
      Argus.Extractors.Supervision,
      Argus.Extractors.Endpoint
    ]

  @sink_fields [
    {:id, :symbol, "instruction ID of the sink call"},
    {:func, :symbol, "function containing the sink"},
    {:api, :symbol, "the API called"},
    {:sink, :symbol, "atom | deserialization | code"}
  ]

  # Keyed on the site, not the (site, entry) pair: a sink reachable from
  # forty controllers is one bug in one place, and reporting it forty
  # times buries it.
  @impl true
  def output_relations do
    [
      %{
        name: :sink_reachable,
        fields:
          @sink_fields ++
            [
              {:entry, :symbol, "a request-handling callback that reaches it"},
              {:kind, :symbol, "which surface the entry belongs to"},
              {:proximity, :symbol, "direct | adjacent | transitive"}
            ],
        key: [:id],
        doc: "A sink reachable from request-shaped input."
      },
      %{
        name: :sink_without_request_path,
        fields: @sink_fields,
        doc: "A sink no request reaches: live code, but not attacker-reachable."
      },
      %{
        name: :sink_endpoint,
        fields: [
          {:sink, :symbol, "the sink site"},
          {:verb, :symbol, "the HTTP method"},
          {:path, :symbol, "the route path"},
          {:plug, :symbol, "the controller or LiveView"}
        ],
        key: [:sink, :verb, :path],
        evidence: %{of: :sink_reachable, on: [sink: :id]},
        doc: "The HTTP endpoints from which an unsafe sink is reachable, attached to its finding."
      },
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
  def finding(:sink_reachable, [id, func, api, "deserialization", entry, kind, proximity]) do
    Findings.new(
      severity(proximity),
      "Unsafe deserialization #{reached(proximity)} #{surface(kind)}",
      "#{func} calls #{api} without the :safe option, and #{entry} reaches " <>
        "it from #{surface(kind)}. On the BEAM this is the strongest of the " <>
        "three: a crafted payload interns atoms without bound AND can " <>
        "materialize funs, ports and references. Pass [:safe] and validate " <>
        "the decoded shape — :safe alone still admits arbitrary nested terms.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:sink_reachable, [id, func, api, "code", entry, kind, proximity]) do
    Findings.new(
      severity(proximity),
      "Dynamic code execution #{reached(proximity)} #{surface(kind)}",
      "#{func} calls #{api}, and #{entry} reaches it from #{surface(kind)}. " <>
        "If any part of that argument is caller-influenced this is arbitrary " <>
        "code execution inside the node, with the full privileges of the VM.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:sink_reachable, [id, func, api, "atom", entry, kind, proximity]) do
    Findings.new(
      severity(proximity),
      "Unbounded atom creation #{reached(proximity)} #{surface(kind)}",
      "#{func} calls #{api}, and #{entry} reaches it from #{surface(kind)}. " <>
        "The atom table is fixed-size and never garbage collected, so every " <>
        "distinct value an attacker supplies permanently consumes a slot " <>
        "until the node aborts — killing every process on it. Use " <>
        "String.to_existing_atom, or match against an explicit whitelist.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:sink_without_request_path, [id, func, api, "atom"]) do
    Findings.new(
      :warning,
      "Dynamic atom creation reachable from an exported function",
      "#{func} calls #{api}, and the module's public surface reaches it. The " <>
        "BEAM atom table is never garbage collected (default cap 1,048,576 " <>
        "entries); if caller-influenced input reaches this call, every new " <>
        "value permanently consumes a slot until the node dies. Prefer " <>
        "String.to_existing_atom or an explicit whitelist.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:sink_without_request_path, [id, func, api, "deserialization"]) do
    Findings.new(
      :error,
      "binary_to_term without :safe",
      "#{func} deserializes with #{api} and no :safe option. Untrusted bytes " <>
        "can intern unbounded atoms and materialize funs, ports, and " <>
        "references — a well-known denial-of-service vector. Pass [:safe] and " <>
        "validate the decoded shape.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:sink_without_request_path, [id, func, api, "code"]) do
    Findings.new(
      :error,
      "Dynamic code execution reachable from exports",
      "#{func} calls #{api}, reachable from an exported function. If any " <>
        "caller-controlled data flows into that call, it is arbitrary code " <>
        "execution inside the node.",
      at: Findings.at_instr(id)
    )
  end

  # The endpoint rather than the callback is the question a reader asks
  # next: a path is something they can try. It does NOT say whether the
  # route is authenticated — Phoenix compiles pipe_through into the
  # router's dispatch as control flow, not into the route table.
  @impl true
  def evidence(:sink_endpoint, [_sink, verb, path, plug]) do
    Findings.related("reachable from #{String.upcase(verb)} #{path}", Findings.at_module(plug))
  end

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

  defp severity("direct"), do: :error
  defp severity("adjacent"), do: :warning
  defp severity(_transitive), do: :info

  defp reached("direct"), do: "directly inside"
  defp reached("adjacent"), do: "one call from"
  defp reached(_), do: "transitively reachable from"

  defp surface("plug"), do: "a Plug (HTTP request)"
  defp surface("live_view"), do: "a LiveView callback"
  defp surface("live_component"), do: "a LiveComponent event"
  defp surface("channel"), do: "a Phoenix Channel (websocket)"
  defp surface("oban_job"), do: "an Oban job"
  defp surface("broadway"), do: "a Broadway pipeline message"
  defp surface(other), do: other
end
