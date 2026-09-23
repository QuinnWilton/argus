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
    only: [
      add_fact: 3,
      attribute_values: 2,
      each_remote_call: 3,
      list_length: 3,
      resolve_register: 3
    ]

  @impl true
  def relations,
    do: [
      :dynamic_call,
      :impure_call,
      :protocol_dispatch,
      :pure_contract,
      :resolved_apply,
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
    each_remote_call(module_data, facts, fn
      acc, ctx, {:erlang, :apply, 3} ->
        resolve_apply(acc, ctx, InstrId.mint(ctx.func_id, ctx.idx))

      acc, ctx, {callee_mod, callee_func, arity} ->
        record(acc, ctx, callee_mod, callee_func, arity)
    end)
  end

  # `apply(M, F, A)` is only opaque when M and F are actually unknown. When
  # they are literals — which is most uses, since `apply` is usually reached
  # through a macro or a dispatch table with constant entries — it is a
  # static call wearing a disguise, and its purity is simply its target's.
  #
  # Argus can already do this: resolve_register/3 walks backwards through
  # the instruction stream to reconstruct what a register holds. So the
  # honest answer is "look first, and only report unprovable if the look
  # fails". Emit still records the dynamic_call unconditionally, because at
  # Layer 1 an apply IS an apply; this relation is the evidence that lets
  # the rules discharge it.
  defp resolve_apply(facts, ctx, id) do
    # The arity is the argument list's length, which only the cons cells
    # that built it can tell: the list's value, as `resolve_register/3`
    # reconstructs it, reads an unknown tail (`[x | rest]`) as one more
    # element, and an improper literal has no length at all.
    with {:ok, mod} when is_atom(mod) <- resolve_register(ctx.instrs, ctx.idx, {:x, 0}),
         {:ok, func} when is_atom(func) <- resolve_register(ctx.instrs, ctx.idx, {:x, 1}),
         arity when is_integer(arity) <- list_length(ctx.instrs, ctx.idx, {:x, 2}) do
      target = InstrId.func_id(mod, func, arity)

      facts
      |> add_fact(:resolved_apply, [id, ctx.func_id, target])
      |> record(ctx, mod, func, arity)
    else
      _ -> facts
    end
  end

  defp record(facts, ctx, callee_mod, callee_func, arity) do
    mod_str = inspect(callee_mod)
    func_str = to_string(callee_func)
    api = "#{mod_str}.#{func_str}/#{arity}"
    id = InstrId.mint(ctx.func_id, ctx.idx)

    case Effects.classify(mod_str, func_str) do
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
