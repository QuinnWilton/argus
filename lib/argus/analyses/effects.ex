defmodule Argus.Analyses.Effects do
  @moduledoc """
  An effect where its context forbids it.

  Two contracts. `@pure true` is a claim the author made: the analysis
  checks it against the call graph and the effect model and says
  verified, violated or unprovable — every call is accounted for, and a
  call it cannot see through produces "unprovable" rather than silence,
  because a purity check that says "verified" when the function writes
  to ETS has actively misled someone. `Repo.transaction/1` is a contract
  nobody writes down: whatever the closure does must be something the
  database can undo, since a rollback leaves the effect behind, a retry
  repeats it, and a pooled connection is held throughout.

  - `purity_violated(func, category, api, via)` — a declared-pure
    function reaches a known observable effect.
  - `purity_unprovable(func, reason, detail, via)` — it reaches a call
    that cannot be followed or classified.
  - `impure_closure_to_pure(caller, callee, closure, category, api)` — a
    caller hands an effectful closure to a function declared pure.
  - `purity_verified(func)` — the claim holds; emitted so "verified" can
    be told from "not looked at".
  - `effect_in_transaction(caller, repo, category, api, via)` — an effect
    inside a transaction body that a rollback cannot undo.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :effects

  @impl true
  def description,
    do: "@pure contracts, and effects inside a transaction that a rollback cannot undo"

  @impl true
  def rules_file, do: "analyses/effects.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Purity,
      # The purity rules join these to classify table writes, port opens
      # and name registration as effects; without them the contract was
      # silently blind to all three.
      Argus.Extractors.ETS,
      Argus.Extractors.ApiCalls,
      Argus.Extractors.ProcessRegistry,
      Argus.Extractors.OTP
    ]

  @impl true
  def output_relations do
    [
      %{
        name: :purity_violated,
        fields: [
          {:func, :symbol, "the function declared pure"},
          {:category, :symbol, "the kind of effect"},
          {:api, :symbol, "the call that performs it"},
          {:via, :symbol, "the function that performs it"}
        ],
        key: [:func, :category, :api],
        doc: "A declared-pure function reaches a known observable effect."
      },
      %{
        name: :purity_unprovable,
        fields: [
          {:func, :symbol, "the function declared pure"},
          {:reason, :symbol, "dynamic_call | unclassified_call"},
          {:detail, :symbol, "the call kind or API"},
          {:via, :symbol, "the function containing it"}
        ],
        key: [:func, :reason, :detail],
        doc: "A declared-pure function reaches something that cannot be accounted for."
      },
      %{
        name: :impure_closure_to_pure,
        fields: [
          {:caller, :symbol, "the function passing the closure"},
          {:callee, :symbol, "the declared-pure function receiving it"},
          {:closure, :symbol, "the lifted closure"},
          {:category, :symbol, "the kind of effect it performs"},
          {:api, :symbol, "the call that performs it"}
        ],
        key: [:caller, :callee, :closure],
        doc: "A caller hands an effectful closure to a function declared pure."
      },
      %{
        name: :purity_verified,
        fields: [{:func, :symbol, "the function declared pure"}],
        key: [:func],
        doc: "A declared-pure function whose reachable calls are all effect-free."
      },
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
  def finding(:purity_violated, [func, category, api, via]) do
    Findings.new(
      :error,
      "#{short(func)} is declared pure but performs #{effect_phrase(category)}",
      "#{func} carries `@pure true`, but #{location(func, via)} calls #{api}, " <>
        "which is #{effect_phrase(category)}. #{consequence(category)} Either " <>
        "remove the declaration or move the effect to the caller.",
      at: Findings.at_func(func)
    )
  end

  def finding(:purity_unprovable, [func, "dynamic_call", kind, via]) do
    Findings.new(
      :warning,
      "#{short(func)} is declared pure but the claim cannot be checked",
      "#{func} carries `@pure true`, but #{location(func, via)} makes a " <>
        "#{kind} — a call through a fun value or a computed module, whose " <>
        "target is not known statically. Whatever it reaches could do " <>
        "anything, so the contract cannot be verified. It may well hold; " <>
        "nothing should rely on it having been checked.",
      at: Findings.at_func(func)
    )
  end

  def finding(:purity_unprovable, [func, "protocol_dispatch", api, via]) do
    Findings.new(
      :warning,
      "#{short(func)} is declared pure but dispatches through a protocol",
      "#{func} carries `@pure true`, and #{location(func, via)} calls " <>
        "#{api}, which resolves to whichever implementation the argument's " <>
        "type provides. Any module can define one, and an implementation is " <>
        "ordinary code — so there is no set of targets to check. This is not " <>
        "a missing entry in the effect model; no model can close it. If the " <>
        "argument's type is known and fixed at this call site, calling that " <>
        "implementation directly makes the contract checkable.",
      at: Findings.at_func(func)
    )
  end

  def finding(:purity_unprovable, [func, "unclassified_call", api, via]) do
    Findings.new(
      :warning,
      "#{short(func)} is declared pure but reaches an unclassified call",
      "#{func} carries `@pure true`, and #{location(func, via)} calls " <>
        "#{api}, which the effect model has no entry for. Argus does not " <>
        "assume unknown calls are harmless — that would make a verification " <>
        "report success far more often and mean nothing. If #{api} really is " <>
        "effect-free, adding it to Argus.Purity.Effects turns this into a " <>
        "verified contract.",
      at: Findings.at_func(func)
    )
  end

  def finding(:impure_closure_to_pure, [caller, callee, closure, category, api]) do
    Findings.new(
      :error,
      "#{short(caller)} passes an effectful closure to a function declared pure",
      "#{callee} carries `@pure true` and calls the fun it is given, so its " <>
        "purity is the caller's obligation. #{caller} builds #{closure}, " <>
        "which calls #{api} — #{effect_phrase(category)} — and hands it over. " <>
        "The contract is broken here, at the call site, not in #{callee}.",
      at: Findings.at_func(caller)
    )
  end

  def finding(:purity_verified, [func]) do
    Findings.new(
      :info,
      "#{short(func)} is verified pure",
      "Every call reachable from #{func} is known to be free of observable " <>
        "effects, including through any closures it constructs.",
      at: Findings.at_func(func)
    )
  end

  def finding(:effect_in_transaction, [caller, repo, category, api, via]) do
    Findings.new(
      rollback_severity(category),
      "#{short(caller)} performs #{rollback_phrase(category)} inside a #{repo} transaction",
      "#{caller} opens a #{repo}.transaction and #{via} calls #{api} inside it. " <>
        "#{rollback_consequence(category)} A rollback cannot take it back, and a retry on a " <>
        "serialization failure will do it twice. #{connection_note(category)}" <>
        "Move the effect outside the transaction, or record the intent in a row and " <>
        "perform it after commit.",
      at: Findings.at_func(caller)
    )
  end

  defp location(func, func), do: "it"
  defp location(_func, via), do: "#{via}, which it reaches,"

  defp short(func) do
    case String.split(func, ":") do
      parts when length(parts) > 1 -> List.last(parts)
      _ -> func
    end
  end

  defp effect_phrase("io"), do: "I/O"
  defp effect_phrase("process"), do: "a process operation"
  defp effect_phrase("process_dict"), do: "a process-dictionary access"
  defp effect_phrase("ets"), do: "a shared-table operation"
  defp effect_phrase("port"), do: "a port or OS interaction"
  defp effect_phrase("node"), do: "a distribution operation"
  defp effect_phrase("time"), do: "a clock or counter read"
  defp effect_phrase("random"), do: "a randomness draw"
  defp effect_phrase("network"), do: "network I/O"
  defp effect_phrase("code_loading"), do: "runtime code loading"
  defp effect_phrase("dynamic"), do: "a dynamic dispatch"
  defp effect_phrase(other), do: other

  defp consequence(c) when c in ["time", "random"],
    do: "The result depends on when it ran, so it is not referentially transparent."

  defp consequence("process_dict"),
    do: "The process dictionary is mutable per-process state that outlives the call."

  defp consequence(c) when c in ["ets", "io", "port", "network", "node"],
    do: "The effect is visible outside the function and survives it."

  defp consequence(_),
    do: "The effect is observable from outside the function."

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
