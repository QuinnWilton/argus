defmodule Argus.Extractors.Purity do
  @moduledoc """
  Purity contracts and call classification.

  Emits three relations:

  - `pure_contract(func, mod, name, arity)` — the functions a module
    declared pure with `@pure true` (see `Argus.Purity`). Read out of the
    beam's attribute chunk, so the contract is taken from the artifact
    rather than the source.
  - `impure_call(id, caller, api, category)` — a call to something with a
    known observable effect.
  - `unknown_call(id, caller, api)` — a call the effect model has no
    opinion about.

  The classification lives in Elixir (`Argus.Purity.Effects`) rather than in
  Datalog for two reasons. It is a large table that wants unit tests and
  doctests, and expressing it as rules would mean either hundreds of facts
  or string surgery — and string surgery in these rules is what produced the
  partial-functor unsoundness fixed in schema v9.
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId
  alias Argus.Purity.Effects

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, match_remote_call: 1, scan_functions: 4]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module

    %{}
    |> extract_contracts(mod, module_data.attributes)
    |> classify_calls(mod, module_data.functions)
  end

  # `@pure true` accumulates {name, arity} into the persisted :argus_pure
  # attribute, which lands in the beam as a list per definition.
  defp extract_contracts(facts, mod, attributes) do
    mod_str = inspect(mod)

    attributes
    |> Keyword.get_values(:argus_pure)
    |> List.flatten()
    |> Enum.reduce(facts, fn
      {name, arity}, acc when is_atom(name) and is_integer(arity) ->
        add_fact(acc, :pure_contract, [
          InstrId.func_id(mod, name, arity),
          mod_str,
          to_string(name),
          to_string(arity)
        ])

      _malformed, acc ->
        acc
    end)
  end

  defp classify_calls(facts, mod, functions) do
    scan_functions(mod, functions, facts, fn acc, ctx, instr ->
      case match_remote_call(instr) do
        {:ok, callee_mod, callee_func, arity} ->
          record(acc, ctx, callee_mod, callee_func, arity)

        :none ->
          acc
      end
    end)
  end

  defp record(facts, ctx, callee_mod, callee_func, arity) do
    mod_str = inspect(callee_mod)
    func_str = to_string(callee_func)
    api = "#{mod_str}.#{func_str}/#{arity}"
    id = InstrId.mint(ctx.func_id, ctx.idx)

    case Effects.classify(mod_str, func_str) do
      {:impure, category} ->
        add_fact(facts, :impure_call, [id, ctx.func_id, api, to_string(category)])

      {:opaque, :protocol} ->
        add_fact(facts, :protocol_dispatch, [id, ctx.func_id, api])

      :pure ->
        facts

      :unknown ->
        add_fact(facts, :unknown_call, [id, ctx.func_id, api])
    end
  end
end
