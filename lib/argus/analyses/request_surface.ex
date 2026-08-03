defmodule Argus.Analyses.RequestSurface do
  @moduledoc """
  Dangerous operations reachable from request-shaped input.

  `Argus.Analyses.AtomSafety` gates the same sinks on "reachable from some
  exported function", which in a library is very nearly everything — it
  answers "is this code live", not "can an attacker reach it". This analysis
  asks the sharper question by starting from OTP callbacks that receive
  external data: `Plug.call/2`, LiveView `mount`/`handle_params`/
  `handle_event`, `Phoenix.Channel.handle_in/3`, `Oban.Worker.perform/1`,
  and Broadway's message callbacks.

  That distinction is the difference between a smell and an incident. A
  `String.to_atom` in a config loader is a smell. The same call reachable
  from `handle_event/3` is a remotely triggerable node kill: the BEAM atom
  table is fixed-size (default 1,048,576) and never garbage collected, so an
  attacker who can send distinct strings permanently consumes slots until
  the VM aborts — taking every process on the node with it, with no
  recovery short of a restart.

  ## Known imprecision

  Reachability is context-insensitive and function-granular, inherited from
  `call_reachable`. A path through a generic dispatcher — anything that
  fans out to many callees — can therefore be spurious. Findings name the
  reaching entry point precisely so that path can be checked by hand, and
  severity is assigned on the assumption that it will be.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :request_surface

  @impl true
  def description, do: "Dangerous operations reachable from request-handling callbacks"

  @impl true
  def rules_file, do: "analyses/request_surface.dl"

  @impl true
  def extractors, do: [Argus.Extractors.AtomSafety, Argus.Extractors.OTP, Argus.Extractors.Router]

  @site_fields [
    {:id, :symbol, "instruction ID of the sink call"},
    {:func, :symbol, "function containing the sink"},
    {:api, :symbol, "the API called"},
    {:entry, :symbol, "a request-handling callback that reaches it"},
    {:kind, :symbol, "which surface the entry belongs to"},
    {:proximity, :symbol, "direct | adjacent | transitive"}
  ]

  # Keyed on the SITE, not the (site, entry) pair: a sink reachable from
  # forty controllers is one bug in one place, and reporting it forty times
  # buries it.
  @impl true
  def output_relations do
    [
      %{
        name: :sink_endpoint,
        fields: [
          {:sink, :symbol, "the sink site"},
          {:verb, :symbol, "the HTTP method"},
          {:path, :symbol, "the route path"},
          {:plug, :symbol, "the controller or LiveView"}
        ],
        key: [:sink, :verb, :path],
        doc: "The HTTP endpoint from which an unsafe sink is reachable."
      },
      %{
        name: :remote_unsafe_deserialization,
        fields: @site_fields,
        key: [:id],
        doc: "binary_to_term without :safe, reachable from request-shaped input."
      },
      %{
        name: :remote_code_execution,
        fields: @site_fields,
        key: [:id],
        doc: "Dynamic code evaluation reachable from request-shaped input."
      },
      %{
        name: :remote_atom_exhaustion,
        fields: @site_fields,
        key: [:id],
        doc: "Unbounded atom creation reachable from request-shaped input."
      }
    ]
  end

  @impl true
  def finding(:sink_endpoint, [sink, verb, path, plug]) do
    Findings.new(
      :info,
      "#{String.upcase(verb)} #{path} reaches #{sink}",
      "#{plug} serves #{String.upcase(verb)} #{path}, and an unsafe sink is " <>
        "reachable from it. This names the endpoint rather than the callback, " <>
        "which is the question a reader asks next — a path is something they " <>
        "can try, and a plug entry point is something they have to go and find. " <>
        "It does NOT say whether the route is authenticated: Phoenix compiles " <>
        "pipe_through into the router's dispatch as control flow rather than " <>
        "into the route table, so that judgement is still yours. The path is " <>
        "often the tell, since projects that separate public routes tend to do " <>
        "it by prefix. " <>
        "Nor does it establish taint. This is reachability — a path exists — " <>
        "and every transitive path examined while calibrating these analyses " <>
        "carried data from storage or configuration rather than from the " <>
        "request. Treat it as a place to look, not as a claim.",
      at: Findings.at_instr(sink)
    )
  end

  @impl true
  def finding(:remote_unsafe_deserialization, [id, func, api, entry, kind, proximity]) do
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

  def finding(:remote_code_execution, [id, func, api, entry, kind, proximity]) do
    Findings.new(
      severity(proximity),
      "Dynamic code execution #{reached(proximity)} #{surface(kind)}",
      "#{func} calls #{api}, and #{entry} reaches it from #{surface(kind)}. " <>
        "If any part of that argument is caller-influenced this is arbitrary " <>
        "code execution inside the node, with the full privileges of the VM.",
      at: Findings.at_instr(id)
    )
  end

  def finding(:remote_atom_exhaustion, [id, func, api, entry, kind, proximity]) do
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

  # Calibrated against hand-verified findings, not chosen a priori.
  #
  # `direct` — the sink is in the callback, operating on the callback's own
  # arguments, which ARE the request. Both direct findings in the corpus
  # were true positives (livebook's `tag`, taken straight from the client
  # payload and converted with no validation against a two-atom domain).
  #
  # `adjacent` — one call away. Mixed: supabase/realtime's `order_by` is a
  # real unvalidated URL parameter, but teslamate's is a database primary
  # key with a domain the size of the user's garage. Worth reading, not
  # worth paging anyone.
  #
  # `transitive` — a path, not a flow. Every transitive hit examined so far
  # sourced its data from Postgres or Redis rather than the request, and
  # was reached only because some LiveView loads those records.
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
