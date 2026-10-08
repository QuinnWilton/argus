defmodule Argus.Analyses.UnsafeInput do
  @moduledoc """
  Attacker-shaped data reaching a sink.

  Tracks atom creation, deserialization, decompression and code execution,
  with separate rules for compressed ETF allocation, cryptographic verdicts,
  runtime templates, SQL construction, raw HTML and upload filesystem paths.
  The general sink findings describe how exposed each operation is:

  - `sink_reachable(id, func, api, sink, entry, kind, proximity, source,
    permille, safety)` — the
    sink is reachable from a request-handling callback (a Plug, a
    controller action, a LiveView, a Channel, an Oban job, a Broadway
    pipeline, a ThousandIsland or WebSock handler). Proximity is
    the triage signal: `flow` means request data provably reaches the
    sink's argument — a parameter of the entry, through destructuring,
    string building and forwarding, however far; `direct` means the sink
    is in the callback itself, operating on the request; `adjacent` one
    call away; `transitive` anywhere else in the callback's cone, a path
    rather than a proven flow. `source` and `permille` are the value
    prior's, as below; `safety` is a deserialization's option class.
  - `sink_without_request_path(id, func, api, sink, source, permille,
    safety)` — no request reaches it: atom creation and decompression of
    what an exported function's caller hands in, code execution reachable
    from an exported function, and every deserialization without `:safe`.
    With priors on, `source` is what the model says the converted value is
    when it is sure, at `permille`, that it is not outside data
    (`Argus.Priors.Questions.ValueSource`, asked of atoms,
    deserializations and code execution); the finding then steps down and
    says so.
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
  summaries do not follow every shape (an unknown external helper's return
  or an unresolved callback) and their silence is not evidence.
  A sink no request reaches keeps the severities the sinks carried when
  they were reported by export reachability alone: deserialization is an
  error, code execution an error, atom creation and decompression a
  warning.
  """

  @behaviour Argus.Analysis

  alias Argus.Analyses.UnsafeInput.CodeInjection
  alias Argus.Analyses.UnsafeInput.EtfAllocation
  alias Argus.Analyses.UnsafeInput.HtmlInjection
  alias Argus.Analyses.UnsafeInput.PathTraversal
  alias Argus.Analyses.UnsafeInput.SqlInjection
  alias Argus.Analyses.UnsafeInput.Verification
  alias Argus.Findings

  @impl true
  def name, do: :unsafe_input

  @impl true
  def description,
    do: "unsafe input, injection, compressed allocation and unenforced cryptographic verification"

  @impl true
  def rules_file, do: "analyses/unsafe_input.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.ApiCalls,
      Argus.Extractors.OTP,
      Argus.Extractors.ParamFlow,
      Argus.Extractors.EtfAllocation,
      Argus.Extractors.TermValidation,
      Argus.Extractors.ResultChecks,
      Argus.Extractors.CodeInjection,
      Argus.Extractors.SqlInjection,
      Argus.Extractors.Generated,
      Argus.Extractors.HtmlInjection,
      Argus.Extractors.PathTraversal,
      Argus.Extractors.Router,
      Argus.Extractors.Supervision,
      # A start whose caller waits for the child's :DOWN (awaits_child_exit).
      Argus.Extractors.Monitor,
      # Where a start hands its fun to a new process (process_start):
      # runs_elsewhere's edges, off a request's own stack.
      Argus.Extractors.TermFlow,
      Argus.Extractors.Endpoint,
      # What a call's arguments are made of whatever the callee
      # (call_arg_reads): whether a caller's input reaches an atom.
      Argus.Extractors.Dependence,
      # A process that makes a socket active (socket_active): its
      # handle_info/2 takes a peer's bytes, no runtime callback.
      Argus.Extractors.Sockets,
      # Literal and forwarded call arguments: a render naming its template.
      Argus.Extractors.CallArgs,
      Argus.Extractors.Tooling,
      # Exports the docs hide (doc_hidden): no way in for a caller's data.
      Argus.Extractors.Docs,
      # Calls a quote names (quoted_call): generated code's, not a beam's.
      Argus.Extractors.Quoted
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
              {:proximity, :symbol, "flow | rendered | direct | adjacent | transitive"},
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
              {:source, :symbol,
               "what the converted value is, when a prior is sure it is not outside data " <>
                 "(configured | code | stored | cluster | operator), else empty"},
              {:permille, :number,
               "the prior's probability that the value is not outside data, in thousandths, else 0"},
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
      },
      Argus.Findings.Tooling.relation()
    ] ++
      EtfAllocation.output_relations() ++
      Verification.output_relations() ++
      CodeInjection.output_relations() ++
      SqlInjection.output_relations() ++
      HtmlInjection.output_relations() ++ PathTraversal.output_relations()
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
    |> requested()
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
    |> requested()
  end

  def finding(:sink_reachable, [id, func, api, "code", entry, kind, proximity, source, p, _s]) do
    Findings.new(
      code_severity(proximity),
      "Dynamic code execution #{reached(proximity)} #{surface(kind)}",
      route(func, api, entry, proximity, kind) <>
        " If any part of that argument is caller-influenced this is arbitrary " <>
        "code execution inside the node, with the full privileges of the VM.",
      [at: Findings.at_instr(id)] ++ route_opts(proximity, "evaluated here", @code_help)
    )
    |> retier(func, proximity, source, p)
    |> at_least(:warning)
    |> requested()
  end

  def finding(:sink_reachable, [id, func, api, "atom", entry, kind, proximity, source, p, _s]) do
    Findings.new(
      severity(proximity),
      "Unbounded atom creation #{reached(proximity)} #{surface(kind)}",
      route(func, atom_api(api), entry, proximity, kind) <>
        " The atom table is fixed-size and never garbage collected. If " <>
        "caller-influenced values reach this conversion, every new atom " <>
        "permanently consumes a slot until the node aborts, killing every " <>
        "process on it.",
      [at: Findings.at_instr(id)] ++
        route_opts(proximity, "atom interned from a string here", @atom_help)
    )
    |> retier(func, proximity, source, p)
    |> requested()
  end

  def finding(:sink_without_request_path, [id, func, api, "atom", source, p, _safety]) do
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
    |> trusted_value("the string it makes an atom of", source, p)
  end

  def finding(:sink_without_request_path, [id, func, api, "deserialization", source, p, safety]) do
    Findings.new(
      deserialization_severity(safety),
      deserialization_title(safety),
      "#{func} deserializes with #{api} #{deserialization_how(safety)}. " <>
        deserialization_risk(safety),
      at: Findings.at_instr(id),
      at_label: "decoded here",
      help: deserialization_help(safety)
    )
    |> trusted_value("what it decodes", source, p)
  end

  def finding(:sink_without_request_path, [id, func, api, "decompression", _source, _p, _safety]) do
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

  def finding(:sink_without_request_path, [id, func, api, "code", source, p, _safety]) do
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
    |> trusted_value("the command it runs", source, p)
    |> Map.put(:floor, :warning)
  end

  def finding(:unbounded_children_from_request, [sup, child, via, kind]) do
    Findings.new(
      :error,
      "Dynamic supervisor starts children without limit, on request",
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

  def finding(:compressed_etf_from_input, row),
    do: EtfAllocation.finding(:compressed_etf_from_input, row)

  def finding(:unchecked_crypto_verification, row),
    do: Verification.finding(:unchecked_crypto_verification, row)

  def finding(:runtime_template_evaluation, row),
    do: CodeInjection.finding(:runtime_template_evaluation, row)

  def finding(:sql_injection, row), do: SqlInjection.finding(:sql_injection, row)

  def finding(:unescaped_html_from_input, row),
    do: HtmlInjection.finding(:unescaped_html_from_input, row)

  def finding(:upload_filename_path_traversal, row),
    do: PathTraversal.finding(:upload_filename_path_traversal, row)

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

  # A sink no request reaches whose value, the model is sure, is not
  # outside data: a heuristic finding a step down that says what the
  # value is (`Argus.Priors.Questions.ValueSource`). No prior, no change.
  @value_kinds %{
    "configured" => "a name or setting the operator configures",
    "code" => "text from the program's own code",
    "stored" => "data the program stored itself",
    "cluster" => "a message from the program's own cluster",
    "operator" => "a developer's or administrator's input to a tool"
  }

  defp trusted_value(attrs, _what, "", _p), do: attrs

  defp trusted_value(attrs, what, source, p) when is_map_key(@value_kinds, source) do
    Findings.heuristic(
      attrs,
      String.to_integer(p),
      "#{what} is #{@value_kinds[source]}, not outside data"
    )
  end

  # What the options said, and what that leaves open. [:safe] stops new
  # atoms and references to unloaded modules; a fun referencing a loaded
  # module decodes fine and runs when the term is used (Paginator
  # CVE-2020-15150 was RCE through [:safe]), so it downgrades and does
  # not clear — only a term-walking decoder such as
  # Plug.Crypto.non_executable_binary_to_term/2 does.
  defp deserialization_title("atoms_only"),
    do: "binary_to_term with [:safe] may admit executable terms"

  defp deserialization_title("dynamic"), do: "binary_to_term with options not known statically"
  defp deserialization_title(_unsafe), do: "binary_to_term without :safe"

  defp deserialization_severity("atoms_only"), do: :warning
  defp deserialization_severity(_unsafe_or_dynamic), do: :error

  defp deserialization_how("atoms_only"), do: "with a literal [:safe] option"
  defp deserialization_how("dynamic"), do: "with options computed at runtime"
  defp deserialization_how(_unsafe), do: "without the :safe option"

  defp deserialization_risk("atoms_only") do
    "[:safe] refuses new atoms and references to unloaded modules, which " <>
      "takes atom-table exhaustion off the table. It does not refuse a fun " <>
      "that references a module already loaded. Calling such a value, or " <>
      "enumerating it through a function-based protocol, can execute it — the " <>
      "shape of Paginator's CVE-2020-15150. This finding does not establish " <>
      "that a decoded function reaches an execution site. A recursive validator " <>
      "may already reject executable terms; no supported complete validation is proven here."
  end

  defp deserialization_risk("dynamic") do
    "Whether :safe is among them cannot be seen here. Without it, untrusted " <>
      "bytes intern unbounded atoms and materialize funs, ports and " <>
      "references. With :safe, executable terms still require validation before use; " <>
      "validation does not prevent atom creation when :safe is missing."
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
  defp severity("rendered"), do: :warning
  defp severity(_transitive), do: :info

  # Code execution a request reaches is never below :warning, whatever
  # the distance and whatever a prior says the function reads. The other
  # sinks' tiers step down with distance because a path is not a flow
  # and the transitive rows read storage; a code sink has no bound a
  # program writes and no value test, so reach from a request is itself
  # the finding. An admin-only route is no exception: argus cannot see
  # `pipe_through`, and an administrator's token reaching code on the
  # host is an escalation past the application's own authority (akkoma's
  # ConfigDB evaluated posted config three ways). `floor:` holds it there
  # past the tooling step too (Argus.Findings.Tooling), as a request's
  # every sink is. So is code execution no request reaches: a value prior
  # takes it to `:warning` at most, and the tooling step no further.
  defp code_severity(proximity), do: at_least(severity(proximity), :warning)

  # A sink a request reaches is the deployed system's, whatever its
  # module's name or path says (a release task an operator's rpc runs, an
  # exam platform's `Test` context): the tooling step does not move it
  # (`floor:`, Argus.Findings.Tooling).
  defp requested(%{severity: severity} = attrs), do: Map.put(attrs, :floor, severity)

  defp at_least(%{severity: severity} = attrs, floor),
    do: %{attrs | severity: at_least(severity, floor)}

  defp at_least(:info, :warning), do: :warning
  defp at_least(severity, _floor), do: severity

  defp reached("flow"), do: "fed by request data from"
  defp reached("direct"), do: "directly inside"
  defp reached("adjacent"), do: "one call from"
  defp reached("rendered"), do: "made of a template's assigns, rendered from"
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

  defp route(func, api, entry, "rendered", kind) do
    "#{func} calls #{api} on what its template is rendered with — the " <>
      "assigns the controller hands it, per request: the request's params " <>
      "and the rows it looked up, of the requester's choosing — and " <>
      "#{entry} reaches it from #{surface(kind)}."
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

  defp route_opts("rendered", _label, help) do
    [at_label: "a template's assigns reach this call's argument", help: help]
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
