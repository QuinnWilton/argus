defmodule Argus.Extractors.Purity do
  @moduledoc """
  Call classification by the effect model (`Argus.EffectModel`).

  Emits:

  - `impure_call(id, caller, api, category, mode)` — a call to something
    with a known observable effect, a guard BIF's `bif` instruction
    included (`self/0`, `node/0`, `:erlang.get/1`).
  - `unknown_call(id, caller, api, callee)` — a call the effect model has
    no opinion about.
  - `protocol_dispatch(id, caller, api)` — a protocol call, whose
    implementations are an open set.
  - `dynamic_call(id, caller, "dot_dispatch")` — a call that runs the
    function it is handed (`:timer.tc/2`).

  The transaction checks, cleanup in `terminate/2`, startup's connection
  checks and the race analysis's state reads all read these rows.

  The name is historical: the extractor first served argus's `@pure`
  contracts, since removed. Its rows never depended on them.

  The classification lives in Elixir rather than in Datalog for two
  reasons. It is a large table that wants unit tests and doctests, and
  expressing it as rules would mean either hundreds of facts or string
  surgery — and string surgery in these rules once produced a
  partial-functor unsoundness.
  """

  @behaviour Argus.Extractor

  alias Argus.EffectModel
  alias Argus.InstrId
  alias Argus.Pipeline.Emit.Applies

  import Argus.Extractor.Helpers, only: [each_remote_call: 3, scan_functions: 4]

  import Argus.Extractor.Facts, only: [add_fact: 3]

  @impl true
  def relations,
    do: [
      :dynamic_call,
      :impure_call,
      :protocol_dispatch,
      :unknown_call
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data), do: classify_calls(%{}, module_data)

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
  # static call wearing a disguise, and its effect is simply its target's.
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

    case EffectModel.classify(mod_str, func_str, arity) do
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
        # whether it is a project function (function_def) without parsing
        # the api string.
        callee = InstrId.func_id(callee_mod, callee_func, arity)
        add_fact(facts, :unknown_call, [id, ctx.func_id, api, callee])
    end
  end
end
