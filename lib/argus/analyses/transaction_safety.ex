defmodule Argus.Analyses.TransactionSafety do
  @moduledoc """
  Side effects inside a database transaction that the database cannot undo.

  `Argus.Analyses.Purity` checks a contract someone wrote down. This one
  checks a contract nobody writes down, because it is imposed by *context*:
  passing a closure to `Repo.transaction/1` silently accepts an obligation
  that whatever the closure does is something the database can take back.

  Three ways that goes wrong, none of them visible in review because the
  offending call looks completely ordinary:

  1. **Rollback leaves the effect behind.** The transaction aborts, the rows
     vanish, and the webhook has already fired. The system is in a state its
     own database says never existed.
  2. **Retry repeats it.** Serialization failures are retried by design —
     that is what an isolation level costs. Each retry re-runs the closure,
     so one logical operation sends two emails.
  3. **The connection is held throughout.** A pooled connection stays
     checked out for the whole closure, so an HTTP call inside a transaction
     couples database capacity to a third party's latency. A slow dependency
     stops being a slow feature and becomes pool exhaustion.

  The third is what takes systems down and is the least obvious: the code is
  correct, it just holds a scarce resource while waiting on something it
  does not control.

  ## Scope

  Not every effect — logging is fine inside a transaction and is by far the
  most common one there; a clock read needs no undoing. What counts is
  effects that escape the database's control, taken from the shared effect
  model in `Argus.Purity.Effects`.

  Repos are found by `Ecto.Repo` behaviour rather than by name, so an app's
  own `MyApp.Repo` is caught without knowing what it is called.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :transaction_safety

  @impl true
  def description, do: "Side effects inside a DB transaction that a rollback cannot undo"

  @impl true
  def rules_file, do: "analyses/transaction_safety.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Purity, Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :effect_in_transaction,
        fields: [
          {:caller, :symbol, "the function opening the transaction"},
          {:repo, :symbol, "the repo"},
          {:category, :symbol, "the kind of effect"},
          {:api, :symbol, "the call performing it"},
          {:via, :symbol, "the function inside the transaction that performs it"}
        ],
        key: [:caller, :category, :api],
        doc: "An effect inside a transaction body that a rollback cannot undo."
      }
    ]
  end

  @impl true
  def finding(:effect_in_transaction, [caller, repo, category, api, via]) do
    Findings.new(
      severity(category),
      "#{short(caller)} performs #{phrase(category)} inside a #{repo} transaction",
      "#{caller} opens a #{repo}.transaction and #{via} calls #{api} inside it. " <>
        "#{consequence(category)} A rollback cannot take it back, and a retry on a " <>
        "serialization failure will do it twice. #{connection_note(category)}" <>
        "Move the effect outside the transaction, or record the intent in a row and " <>
        "perform it after commit.",
      at: Findings.at_func(caller)
    )
  end

  # Network is worse than the rest: as well as being unrollbackable it holds
  # a pooled connection for the duration of somebody else's latency, which
  # is the failure mode that becomes an outage rather than a bad row.
  defp severity(c) when c in ["network", "port"], do: :error
  defp severity(_), do: :warning

  defp phrase("network"), do: "network I/O"
  defp phrase("port"), do: "an OS or port operation"
  defp phrase("process"), do: "a process operation"
  defp phrase("io"), do: "file I/O"
  defp phrase("ets"), do: "a shared-table write"
  defp phrase("node"), do: "a distribution operation"
  defp phrase(other), do: other

  defp consequence("network"), do: "The request has already left the machine."

  defp consequence("process"),
    do: "The message has already been delivered, or the process already spawned."

  defp consequence("ets"),
    do: "ETS is not transactional, so the write stands regardless of the outcome."

  defp consequence(_), do: "The effect is already visible outside the database."

  defp connection_note(c) when c in ["network", "port"] do
    "It also holds a pooled database connection for the whole call, so this " <>
      "dependency's latency becomes your connection pool's occupancy — the usual " <>
      "route from a slow third party to an outage. "
  end

  defp connection_note(_), do: ""

  defp short(func) do
    case String.split(func, ":") do
      parts when length(parts) > 1 -> List.last(parts)
      _ -> func
    end
  end
end
