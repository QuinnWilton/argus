defmodule Argus.Extractors.Purity do
  @moduledoc """
  Purity contracts and call classification.

  Emits three relations:

  - `pure_contract(func, mod, name, arity)` — the functions a module
    declared pure with `@pure true` (see `Argus.Purity`). Read out of the
    beam's attribute chunk, so the contract is taken from the artifact
    rather than the source.
  - `impure_call(id, caller, api, category)` — a call to something with a
    known observable effect, a guard BIF's `bif` instruction included
    (`self/0`, `node/0`, `:erlang.get/1`).
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
  alias Argus.Pipeline.Emit.Applies
  alias Argus.Purity.Effects

  import Argus.Extractor.Helpers,
    only: [attribute_values: 2, each_remote_call: 3, scan_functions: 4]

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations,
    do: [
      :dynamic_call,
      :impure_call,
      :protocol_dispatch,
      :pure_contract,
      :unknown_call
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    mod = module_data.module

    %{}
    |> extract_contracts(mod, module_data.attributes)
    |> classify_calls(module_data)
  end

  # `@pure true` accumulates {name, arity} into the persisted :argus_pure
  # attribute, which lands in the beam as a list per definition.
  defp extract_contracts(facts, mod, attributes) do
    mod_str = inspect(mod)

    attributes
    |> attribute_values(:argus_pure)
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

  defp classify_calls(facts, module_data) do
    facts =
      each_remote_call(module_data, facts, fn
        acc, ctx, {:erlang, :apply, arity} when arity in [2, 3] ->
          record_apply(acc, ctx)

        acc, ctx, {callee_mod, callee_func, arity} ->
          record(acc, ctx, callee_mod, callee_func, arity)
      end)

    scan_functions(module_data.module, module_data.functions, facts, fn
      acc, ctx, {:apply, _} -> record_apply(acc, ctx)
      acc, ctx, {:apply_last, _, _} -> record_apply(acc, ctx)
      acc, ctx, {:bif, name, _fail, args, _dst} -> record_bif(acc, ctx, name, args)
      acc, ctx, {:gc_bif, name, _fail, _live, args, _dst} -> record_bif(acc, ctx, name, args)
      acc, _ctx, _instr -> acc
    end)
  end

  # A guard BIF compiles to a `bif` (or `gc_bif`) instruction, not a call:
  # `self/0`, `node/0` and `:erlang.get/1` are effects the remote-call
  # scan never sees. Classified by the same model as `:erlang` calls.
  defp record_bif(facts, ctx, name, args) when is_atom(name) and is_list(args),
    do: record(facts, ctx, :erlang, name, length(args))

  defp record_bif(facts, _ctx, _name, _args), do: facts

  # `apply(M, F, A)` is only opaque when M and F are actually unknown.
  # When they resolve (`Argus.Pipeline.Emit.Applies`, whose
  # `resolved_apply` row discharges the apply's `dynamic_call`) it is a
  # static call wearing a disguise, and its purity is simply its target's.
  defp record_apply(facts, ctx) do
    case Applies.resolve(ctx.instrs, ctx.idx, Enum.at(ctx.instrs, ctx.idx)) do
      {:ok, {mod, func, arity}} -> record(facts, ctx, mod, func, arity)
      :error -> facts
    end
  end

  defp record(facts, ctx, callee_mod, callee_func, arity) do
    mod_str = inspect(callee_mod)
    func_str = to_string(callee_func)
    api = "#{mod_str}.#{func_str}/#{arity}"
    id = InstrId.mint(ctx.func_id, ctx.idx)

    case Effects.classify(mod_str, func_str, arity) do
      {:impure, category, mode} ->
        add_fact(facts, :impure_call, [
          id,
          ctx.func_id,
          api,
          to_string(category),
          to_string(mode)
        ])

      {:opaque, :protocol} ->
        add_fact(facts, :protocol_dispatch, [id, ctx.func_id, api])

      :pure ->
        facts

      {:opaque, :dot_dispatch} ->
        add_fact(facts, :dynamic_call, [id, ctx.func_id, "dot_dispatch"])

      :unknown ->
        # The callee's func_id travels alongside so the rules can ask
        # whether IT declared itself pure, without parsing the api string.
        callee = InstrId.func_id(callee_mod, callee_func, arity)
        add_fact(facts, :unknown_call, [id, ctx.func_id, api, callee])
    end
  end
end
