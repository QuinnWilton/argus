defmodule Argus.Analyses.Effects do
  @moduledoc """
  Effects inside a database transaction that a rollback cannot undo.

  `Repo.transaction/1` is a contract nobody writes down: whatever the
  closure does must be something the database can undo, since a rollback
  leaves the effect behind, a retry repeats it, and a pooled connection is
  held throughout.

  - `effect_in_context(func, context, scope, category, api, via, site,
    opened)` — an effect inside a transaction body, opened at `opened` by
    `func` on the repo in `scope`, that a rollback cannot undo. `via` is
    the function performing it and `site` the call. `context` is always
    `transaction`: the column stays so that the relation's shape, and the
    identities of the findings it reports, are those earlier releases
    reported.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :effects

  @impl true
  def description, do: "effects inside a transaction that a rollback cannot undo"

  @impl true
  def rules_file, do: "analyses/effects.dl"

  @impl true
  def extractors,
    do: [
      # impure_call: the effect model's classification of every call.
      Argus.Extractors.Purity,
      # implements_behaviour: which modules are an Ecto.Repo.
      Argus.Extractors.OTP,
      # Where a transaction's body starts a process (process_start):
      # runs_elsewhere's edges, which the transaction walk treats apart.
      Argus.Extractors.TermFlow,
      Argus.Extractors.Tooling
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :effect_in_context,
        fields: [
          {:func, :symbol, "the function opening the transaction"},
          {:context, :symbol, "transaction"},
          {:scope, :symbol, "the repo the transaction is on"},
          {:category, :symbol, "the kind of effect"},
          {:api, :symbol, "the call that performs it"},
          {:via, :symbol, "the function that performs it"},
          {:site, :symbol, "the instruction performing it"},
          {:opened, :symbol, "the transaction call"}
        ],
        key: [:func, :context, :category, :api],
        doc: "An effect inside a transaction body that a rollback cannot undo."
      },
      Argus.Findings.Tooling.relation()
    ]
  end

  @impl true
  def finding(:effect_in_context, [
        caller,
        "transaction",
        repo,
        category,
        api,
        via,
        site,
        opened
      ]) do
    Findings.new(
      rollback_severity(category),
      "#{upcase_first(rollback_phrase(category))} inside a transaction",
      "#{caller} opens a #{repo}.transaction and #{via} calls #{api} inside it. " <>
        "#{rollback_consequence(category)} A rollback cannot take it back, and a retry on a " <>
        "serialization failure will do it twice. #{connection_note(category)}",
      at: Findings.at_site_in_func(opened, caller),
      at_label: "opens the transaction here",
      related: effect_frame("#{rollback_phrase(category)} inside it, here", site),
      help: [
        "move the effect outside the transaction, or record the intent in a row " <>
          "and perform it after commit"
      ]
    )
  end

  # A frame at the call a finding is about, when its site names an
  # instruction.
  defp effect_frame(label, site) do
    case Findings.at_instr(site) do
      %{instr: nil} -> []
      anchor -> [Findings.related(label, anchor)]
    end
  end

  # A title's first letter, whatever the phrase starts with ("I/O" stays
  # as it is; String.capitalize/1 would lower the rest).
  defp upcase_first(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  # Network is worse than the rest: as well as being unrollbackable it holds
  # a pooled connection for the duration of somebody else's latency, which
  # is the failure mode that becomes an outage rather than a bad row.
  defp rollback_severity(c) when c in ["network", "port"], do: :error
  defp rollback_severity(_), do: :warning

  defp rollback_phrase("network"), do: "network I/O"
  defp rollback_phrase("port"), do: "an OS or port operation"
  defp rollback_phrase("process"), do: "a process operation"
  defp rollback_phrase("io"), do: "file I/O"
  defp rollback_phrase("ets"), do: "a shared-table write"
  defp rollback_phrase("node"), do: "a distribution operation"
  defp rollback_phrase(other), do: other

  defp rollback_consequence("network"), do: "The request has already left the machine."

  defp rollback_consequence("process"),
    do: "The message has already been delivered, or the process already spawned."

  defp rollback_consequence("ets"),
    do: "ETS is not transactional, so the write stands regardless of the outcome."

  defp rollback_consequence(_), do: "The effect is already visible outside the database."

  defp connection_note(c) when c in ["network", "port"] do
    "It also holds a pooled database connection for the whole call, so this " <>
      "dependency's latency becomes your connection pool's occupancy — the usual " <>
      "route from a slow third party to an outage. "
  end

  defp connection_note(_), do: ""
end
