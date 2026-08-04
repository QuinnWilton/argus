defmodule Argus.Analyses.Purity do
  @moduledoc """
  Verifies `@pure true` contracts (see `Argus.Purity`).

  Every other argus analysis looks for a bug nobody claimed was absent.
  This one checks a claim the author made, which changes what a finding
  means: not "this looks suspicious" but "you said this function has no side
  effects, and here is the call that gives it one".

  It is also the only analysis here that has to be *sound* rather than
  merely useful. A missed supervision smell costs a warning; a purity check
  that reports "verified" for a function that writes to ETS has actively
  misled someone into depending on it. So there are three outcomes, not two:

  - `purity_violated` — reaches a call with a known observable effect.
  - `purity_unprovable` — reaches a call that cannot be followed (a fun
    value, `apply`) or that the effect model has no entry for.
  - `purity_verified` — everything reachable is known to be effect-free.

  The third is emitted on purpose. A contract is only worth having if you
  can tell it was actually checked, and an analysis that reports only
  failures cannot distinguish "verified" from "never looked at".
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :purity

  @impl true
  def description, do: "Verify @pure contracts against the call graph and an effect model"

  @impl true
  def rules_file, do: "analyses/purity.dl"

  @impl true
  def extractors,
    do: [
      Argus.Extractors.Purity,
      # purity's rules join these to classify table writes, port opens and
      # name registration as effects. Declaring only the Purity extractor
      # left them empty, so the contract was silently blind to all three.
      Argus.Extractors.ETS,
      Argus.Extractors.Ports,
      Argus.Extractors.ProcessRegistry
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
end
