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

  - `effect_in_context(func, context, scope, category, api, via, site,
    opened)` — an effect where its context forbids it: `pure_contract` (a
    declared-pure function reaches a known observable effect) or
    `transaction` (an effect inside a transaction body, opened at
    `opened` on the repo in `scope`, that a rollback cannot undo). `site`
    is the call performing the effect.
  - `purity_unprovable(func, reason, detail, via, site)` — it reaches a
    call that cannot be followed or classified.
  - `impure_closure_to_pure(caller, callee, closure, category, api, site,
    effect_site)` — a caller hands an effectful closure to a function
    declared pure, at `site`.
  - `purity_verified(func)` — the claim holds; emitted so "verified" can
    be told from "not looked at".
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
        name: :effect_in_context,
        fields: [
          {:func, :symbol, "the function the contract applies to"},
          {:context, :symbol, "pure_contract | transaction"},
          {:scope, :symbol, "the repo for a transaction, empty for a pure contract"},
          {:category, :symbol, "the kind of effect"},
          {:api, :symbol, "the call that performs it"},
          {:via, :symbol, "the function that performs it"},
          {:site, :symbol, "the instruction performing it; empty for a receive"},
          {:opened, :symbol, "the transaction call, for a transaction; else empty"}
        ],
        key: [:func, :context, :category, :api],
        doc: "An effect where its context forbids it: a @pure claim, or a transaction body."
      },
      %{
        name: :purity_unprovable,
        fields: [
          {:func, :symbol, "the function declared pure"},
          {:reason, :symbol, "dynamic_call | unclassified_call"},
          {:detail, :symbol, "the call kind or API"},
          {:via, :symbol, "the function containing it"},
          {:site, :symbol, "the call that cannot be followed"}
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
          {:api, :symbol, "the call that performs it"},
          {:site, :symbol, "the call handing the closure to the pure function"},
          {:effect_site, :symbol, "the effect inside the closure"}
        ],
        key: [:caller, :callee, :closure],
        doc: "A caller hands an effectful closure to a function declared pure."
      },
      %{
        name: :purity_verified,
        fields: [{:func, :symbol, "the function declared pure"}],
        key: [:func],
        doc: "A declared-pure function whose reachable calls are all effect-free."
      }
    ]
  end

  @impl true
  def finding(:effect_in_context, [func, "pure_contract", _, category, api, via, site, _]) do
    Findings.new(
      :error,
      "#{short(func)} is declared pure but performs #{effect_phrase(category)}",
      "#{func} carries `@pure true`, but #{location(func, via)} calls #{api}, " <>
        "which is #{effect_phrase(category)}. #{consequence(category)}",
      at: Findings.at_func(func),
      at_label: "declared pure here",
      related: effect_frame("#{effect_phrase(category)} here", site),
      help: ["remove `@pure true`, or move the effect to the caller"]
    )
  end

  def finding(:purity_unprovable, [func, "dynamic_call", kind, via, site]) do
    Findings.new(
      :warning,
      "#{short(func)} is declared pure but the claim cannot be checked",
      "#{func} carries `@pure true`, but #{location(func, via)} makes a " <>
        "#{kind} — a call through a fun value or a computed module, whose " <>
        "target is not known statically. Whatever it reaches could do " <>
        "anything, so the contract cannot be verified. It may well hold; " <>
        "nothing should rely on it having been checked.",
      at: Findings.at_func(func),
      at_label: "declared pure here",
      related: effect_frame("the call whose target is not known", site),
      help: ["call a known module and function so the claim can be checked, or drop `@pure`"]
    )
  end

  def finding(:purity_unprovable, [func, "protocol_dispatch", api, via, site]) do
    Findings.new(
      :warning,
      "#{short(func)} is declared pure but dispatches through a protocol",
      "#{func} carries `@pure true`, and #{location(func, via)} calls " <>
        "#{api}, which resolves to whichever implementation the argument's " <>
        "type provides. Any module can define one, and an implementation is " <>
        "ordinary code — so there is no set of targets to check. This is not " <>
        "a missing entry in the effect model; no model can close it.",
      at: Findings.at_func(func),
      at_label: "declared pure here",
      related: effect_frame("dispatches through the protocol here", site),
      help: [
        "if the argument's type is fixed at that call site, call its implementation " <>
          "directly so the contract can be checked"
      ]
    )
  end

  def finding(:purity_unprovable, [func, "unclassified_call", api, via, site]) do
    Findings.new(
      :warning,
      "#{short(func)} is declared pure but reaches an unclassified call",
      "#{func} carries `@pure true`, and #{location(func, via)} calls " <>
        "#{api}, which the effect model has no entry for. Argus does not " <>
        "assume unknown calls are harmless — that would make a verification " <>
        "report success far more often and mean nothing.",
      at: Findings.at_func(func),
      at_label: "declared pure here",
      related: effect_frame("the call the effect model has no entry for", site),
      help: [
        "if #{api} is effect-free, add it to Argus.Purity.Effects and this becomes " <>
          "a verified contract; otherwise drop `@pure`"
      ]
    )
  end

  def finding(:impure_closure_to_pure, [
        caller,
        callee,
        closure,
        category,
        api,
        site,
        effect_site
      ]) do
    Findings.new(
      :error,
      "#{short(caller)} passes an effectful closure to a function declared pure",
      "#{callee} carries `@pure true` and calls the fun it is given, so its " <>
        "purity is the caller's obligation. #{caller} builds #{closure}, " <>
        "which calls #{api} — #{effect_phrase(category)} — and hands it over. " <>
        "The contract is broken here, at the call site, not in #{callee}.",
      at: Findings.at_site_in_func(site, caller),
      at_label: "hands the effectful closure to #{short(callee)} here",
      related: effect_frame("the closure calls #{api} here", effect_site),
      help: [
        "perform the effect before or after the call and pass a pure fun, " <>
          "or drop `@pure` from #{callee}"
      ]
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
      "#{short(caller)} performs #{rollback_phrase(category)} inside a #{repo} transaction",
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

  # A frame at the call a finding is about, when the rule had one: a
  # receive, which is no single instruction, has none.
  defp effect_frame(label, site) do
    case Findings.at_instr(site) do
      %{instr: nil} -> []
      anchor -> [Findings.related(label, anchor)]
    end
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
