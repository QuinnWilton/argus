defmodule Argus.Analyses.UnsafeInput do
  @moduledoc """
  Attacker-shaped data reaching a sink.

  Four sinks matter on the BEAM: atom creation (the atom table is
  fixed-size and never collected), deserialization (`binary_to_term`
  materializes funs, ports and references), one-shot decompression (the
  whole output of an input with no bound on its size) and code
  execution. Each is reported once, with how exposed it is:

  - `sink_reachable(id, func, api, sink, entry, kind, proximity)` — the
    sink is reachable from a request-handling callback (a Plug, a
    controller action, a LiveView, a Channel, an Oban job, a Broadway
    pipeline, a ThousandIsland or WebSock handler). Proximity is
    the triage signal: `flow` means request data provably reaches the
    sink's argument — a parameter of the entry, through destructuring,
    string building and forwarding, however far; `direct` means the sink
    is in the callback itself, operating on the request; `adjacent` one
    call away; `transitive` anywhere else in the callback's cone, a path
    rather than a proven flow.
  - `sink_without_request_path(id, func, api, sink, safety)` — no request reaches
    it: atom creation and decompression of what an exported function's
    caller hands in, code execution reachable from an exported function,
    and every deserialization without `:safe`.
  - `sink_endpoint(sink, verb, path, plug)` — the HTTP route a sink is
    reachable from, when the router literal names one.
  - `unbounded_children_from_request(sup, child, via, kind)` —
    `start_child` on an uncapped DynamicSupervisor, reachable from a
    request: processes an outside party can create without limit.

  Severity follows proximity, calibrated against hand-verified findings:
  every direct finding in the corpus was real (livebook's `tag`, taken
  straight from the client payload), adjacent was mixed, and every
  transitive hit sourced its data from storage rather than the request.
  A proven flow is an error at any distance; a path that the flow
  summaries could not confirm keeps the proximity it had, since the
  summaries do not follow every shape (a local helper's return, an
  element handed to a closure) and their silence is not evidence.
  A sink no request reaches keeps the severities the sinks carried when
  they were reported by export reachability alone: deserialization is an
  error, code execution an error, atom creation and decompression a
  warning.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :unsafe_input

  @impl true
  def description,
    do:
      "atom exhaustion, unsafe deserialization, unbounded decompression and code execution " <>
        "reachable from a request"

  @impl true
  def rules_file, do: "analyses/unsafe_input.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ApiCalls,
      Argus.Extractors.OTP,
      Argus.Extractors.ParamFlow,
      Argus.Extractors.Router,
      Argus.Extractors.Supervision,
      Argus.Extractors.Endpoint,
      # What a call's arguments are made of whatever the callee
      # (call_arg_reads): whether a caller's input reaches an atom.
      Argus.Extractors.Dependence
    ]

  @sink_fields [
    {:id, :symbol, "instruction ID of the sink call"},
    {:func, :symbol, "function containing the sink"},
    {:api, :symbol, "the API called"},
    {:sink, :symbol, "atom | deserialization | decompression | code"}
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
              {:proximity, :symbol, "flow | direct | adjacent | transitive"},
              {:source, :symbol,
               "what the sink's function reads, when a prior says (request | storage | config | internal | passthrough | constant), else empty"},
              {:permille, :number, "the prior's probability in thousandths, else 0"},
              {:safety, :symbol,
               "for a deserialization, its option class: unsafe | atoms_only | dynamic; else empty"}
            ],
        key: [:id],
        doc: "A sink reachable from request-shaped input."
      },
      %{
        name: :sink_without_request_path,
        fields:
          @sink_fields ++
            [
              {:safety, :symbol,
               "for a deserialization, its option class: unsafe | atoms_only | dynamic; else empty"}
            ],
        doc: "A sink no request reaches: live code, but not attacker-reachable."
      },
      %{
        name: :sink_export,
        fields: [
          {:sink, :symbol, "the sink site"},
          {:export, :symbol, "an exported function that reaches it"}
        ],
        key: [:sink, :export],
        evidence: %{of: :sink_without_request_path, on: [sink: :id], limit: 3},
        doc:
          "Exported functions a sink no request reaches is reachable from, within six calls, " <>
            "attached to its finding."
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

  @atom_help [
    "validate the value against an explicit allowlist before converting it",
    "String.to_existing_atom/1, or a pattern match on the accepted values, " <>
      "turns unbounded input into a bounded set"
  ]

  @code_help [
    "dispatch on an allowlist of known modules and functions rather than " <>
      "names built from data"
  ]

  @inflate_help [
    "inflate in bounded chunks (`:zlib.safeInflate/2` or `inflateChunk/2`) and stop past a cap",
    "or refuse a body whose size the transport has not already bounded"
  ]

  @inflate_risk " A few hundred bytes of compressed (or layered) input can " <>
                  "inflate to gigabytes, and the whole output is built in the " <>
                  "process's heap before anything can look at its size — the " <>
                  "shape of Bandit's and Tesla's advisories."

  @impl true
  def finding(:sink_reachable, [
        id,
        func,
        api,
        "decompression",
        entry,
        kind,
        proximity,
        source,
        p,
        _s
      ]) do
    Findings.new(
      severity(proximity),
      "Unbounded decompression #{reached(proximity)} #{surface(kind)}",
      route(func, api, entry, proximity, kind) <> @inflate_risk,
      [at: Findings.at_instr(id)] ++
        route_opts(proximity, "inflated with no size bound here", @inflate_help)
    )
    |> retier(func, proximity, source, p)
  end

  def finding(:sink_reachable, [
        id,
        func,
        api,
        "deserialization",
        entry,
        kind,
        proximity,
        source,
        p,
        safety
      ]) do
    Findings.new(
      severity(proximity),
      "#{deserialization_title(safety)} #{reached(proximity)} #{surface(kind)}",
      route(func, "#{api} #{deserialization_how(safety)}", entry, proximity, kind) <>
        " " <> deserialization_risk(safety),
      [at: Findings.at_instr(id)] ++
        route_opts(proximity, "decoded here", deserialization_help(safety))
    )
    |> retier(func, proximity, source, p)
  end

  def finding(:sink_reachable, [id, func, api, "code", entry, kind, proximity, source, p, _s]) do
    Findings.new(
      severity(proximity),
      "Dynamic code execution #{reached(proximity)} #{surface(kind)}",
      route(func, api, entry, proximity, kind) <>
        " If any part of that argument is caller-influenced this is arbitrary " <>
        "code execution inside the node, with the full privileges of the VM.",
      [at: Findings.at_instr(id)] ++ route_opts(proximity, "evaluated here", @code_help)
    )
    |> retier(func, proximity, source, p)
  end

  def finding(:sink_reachable, [id, func, api, "atom", entry, kind, proximity, source, p, _s]) do
    Findings.new(
      severity(proximity),
      "Unbounded atom creation #{reached(proximity)} #{surface(kind)}",
      route(func, atom_api(api), entry, proximity, kind) <>
        " The atom table is fixed-size and never garbage collected, so every " <>
        "distinct value an attacker supplies permanently consumes a slot " <>
        "until the node aborts — killing every process on it.",
      [at: Findings.at_instr(id)] ++
        route_opts(proximity, "atom interned from a string here", @atom_help)
    )
    |> retier(func, proximity, source, p)
  end

  def finding(:sink_without_request_path, [id, func, api, "atom", _safety]) do
    Findings.new(
      :warning,
      "Dynamic atom creation reachable from an exported function",
      "#{func} calls #{atom_api(api)}, and the module's public surface reaches it. " <>
        "The BEAM atom table is never garbage collected (default cap 1,048,576 " <>
        "entries); if caller-influenced input reaches this call, every new " <>
        "value permanently consumes a slot until the node dies.",
      at: Findings.at_instr(id),
      at_label: "atom interned from a string here",
      help: @atom_help
    )
  end

  def finding(:sink_without_request_path, [id, func, api, "deserialization", safety]) do
    Findings.new(
      deserialization_severity(safety),
      deserialization_title(safety),
      "#{func} deserializes with #{api} #{deserialization_how(safety)}. " <>
        deserialization_risk(safety),
      at: Findings.at_instr(id),
      at_label: "decoded here",
      help: deserialization_help(safety)
    )
  end

  def finding(:sink_without_request_path, [id, func, api, "decompression", _safety]) do
    Findings.new(
      :warning,
      "Unbounded decompression of a caller's input",
      "#{func} calls #{api} on data an exported function's caller hands in." <>
        @inflate_risk,
      at: Findings.at_instr(id),
      at_label: "inflated with no size bound here",
      help: @inflate_help
    )
  end

  def finding(:sink_without_request_path, [id, func, api, "code", _safety]) do
    Findings.new(
      :error,
      "Dynamic code execution reachable from exports",
      "#{func} calls #{api}, reachable from an exported function. If any " <>
        "caller-controlled data flows into that call, it is arbitrary code " <>
        "execution inside the node.",
      at: Findings.at_instr(id),
      at_label: "evaluated here",
      help: @code_help
    )
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
        "the handler each read fine in isolation.",
      at: Findings.at_func(via),
      at_label: "starts a child per request",
      related: [Findings.related("supervisor", Findings.at_module(sup))],
      help: [
        "set `max_children` on #{sup}",
        "decide what start_child returning `{:error, :max_children}` means for the " <>
          "caller — refusing one request is what stops it becoming an outage for all"
      ]
    )
  end

  # The endpoint rather than the callback is the question a reader asks
  # next: a path is something they can try. It does NOT say whether the
  # route is authenticated — Phoenix compiles pipe_through into the
  # router's dispatch as control flow, not into the route table.
  @impl true
  def evidence(:sink_export, [_sink, export]) do
    Findings.related("reachable from #{export}, which is exported", Findings.at_func(export))
  end

  def evidence(:sink_endpoint, [_sink, verb, path, plug]) do
    Findings.related("reachable from #{String.upcase(verb)} #{path}", Findings.at_module(plug))
  end

  # A path row whose sink function, the model says, reads storage,
  # configuration or the system's own state: the path is real, the data
  # is probably not the request. A heuristic finding (`Findings.heuristic/3`)
  # that says what was read and how sure the model was. A function
  # the model calls passthrough or request-reading is left as it is —
  # the first says nothing, the second was unmeasured in calibration.
  @downgrading ~w(storage config internal constant)

  defp retier(attrs, func, proximity, source, p)
       when proximity in ["adjacent", "transitive"] and source in @downgrading do
    Findings.heuristic(attrs, String.to_integer(p), "#{func} reads #{source}, not the request")
  end

  defp retier(attrs, _func, _proximity, _source, _p), do: attrs

  # What the options said, and what that leaves open. [:safe] stops new
  # atoms and references to unloaded modules; a fun referencing a loaded
  # module decodes fine and runs when the term is used (Paginator
  # CVE-2020-15150 was RCE through [:safe]), so it downgrades and does
  # not clear — only a term-walking decoder such as
  # Plug.Crypto.non_executable_binary_to_term/2 does.
  defp deserialization_title("atoms_only"), do: "binary_to_term with [:safe] and no shape check"
  defp deserialization_title("dynamic"), do: "binary_to_term with options not known statically"
  defp deserialization_title(_unsafe), do: "binary_to_term without :safe"

  defp deserialization_severity("atoms_only"), do: :warning
  defp deserialization_severity(_unsafe_or_dynamic), do: :error

  defp deserialization_how("atoms_only"), do: "with [:safe] and nothing else"
  defp deserialization_how("dynamic"), do: "with options computed at runtime"
  defp deserialization_how(_unsafe), do: "without the :safe option"

  defp deserialization_risk("atoms_only") do
    "[:safe] refuses new atoms and references to unloaded modules, which " <>
      "takes atom-table exhaustion off the table. It does not refuse a fun " <>
      "that references a module already loaded, and the first thing that " <>
      "enumerates or calls the decoded term runs it — the shape of Paginator's " <>
      "CVE-2020-15150."
  end

  defp deserialization_risk("dynamic") do
    "Whether :safe is among them cannot be seen here. Without it, untrusted " <>
      "bytes intern unbounded atoms and materialize funs, ports and " <>
      "references; with it, a fun referencing a loaded module still runs."
  end

  defp deserialization_risk(_unsafe) do
    "Untrusted bytes can intern unbounded atoms and materialize funs, ports, " <>
      "and references — a well-known denial-of-service vector, and on the " <>
      "BEAM the strongest of the three sinks."
  end

  defp deserialization_help("atoms_only") do
    [
      "validate the decoded shape before using it",
      "or decode with `Plug.Crypto.non_executable_binary_to_term/2`"
    ]
  end

  defp deserialization_help("dynamic") do
    ["pass `[:safe]` as a literal and validate the decoded shape"]
  end

  defp deserialization_help(_unsafe) do
    [
      "pass `[:safe]` and validate the decoded shape — :safe alone still admits arbitrary nested terms"
    ]
  end

  # The compiled form of String.to_atom/1 and List.to_atom/1 is what the
  # facts see; the reader sees the source.
  defp atom_api(":erlang.binary_to_atom/" <> _ = api), do: "String.to_atom (compiled to #{api})"
  defp atom_api(":erlang.list_to_atom/" <> _ = api), do: "List.to_atom (compiled to #{api})"
  defp atom_api(api), do: api

  defp severity("flow"), do: :error
  defp severity("direct"), do: :error
  defp severity("adjacent"), do: :warning
  defp severity(_transitive), do: :info

  defp reached("flow"), do: "fed by request data from"
  defp reached("direct"), do: "directly inside"
  defp reached("adjacent"), do: "one call from"
  defp reached(_), do: "transitively reachable from"

  # How the sink and the entry relate, in one sentence. A flow is a claim
  # about the data; a path is a claim about the calls. When the entry is
  # the sink's own function there is no second party to name.
  defp route(func, api, func, "flow", kind) do
    "#{func} calls #{api} with its own request data — through destructuring, " <>
      "string construction and forwarding, a flow rather than a path — from " <>
      "#{surface(kind)}."
  end

  defp route(func, api, entry, "flow", kind) do
    "#{func} calls #{api}, and #{entry} hands its request data into that " <>
      "argument — through destructuring, string construction and forwarding, " <>
      "a flow rather than a path — from #{surface(kind)}."
  end

  defp route(func, api, func, _proximity, kind) do
    "#{func} calls #{api} from #{surface(kind)}."
  end

  defp route(func, api, entry, _proximity, kind) do
    "#{func} calls #{api}, and #{entry} reaches it from #{surface(kind)}."
  end

  defp route_opts("flow", _label, help) do
    [at_label: "request data reaches this call's argument", help: help]
  end

  defp route_opts(_proximity, label, help), do: [at_label: label, help: help]

  defp surface("plug"), do: "a Plug (HTTP request)"
  defp surface("controller"), do: "a Phoenix controller action (HTTP request)"
  defp surface("live_view"), do: "a LiveView callback"
  defp surface("live_component"), do: "a LiveComponent event"
  defp surface("channel"), do: "a Phoenix Channel (websocket)"
  defp surface("oban_job"), do: "an Oban job"
  defp surface("broadway"), do: "a Broadway pipeline message"
  defp surface("socket"), do: "a ThousandIsland handler (socket data)"
  defp surface("websocket"), do: "a WebSock handler (websocket frame)"
  defp surface(other), do: other
end
