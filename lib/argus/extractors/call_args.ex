defmodule Argus.Extractors.CallArgs do
  @moduledoc """
  Call-site argument extractor.

  Emits one fact per resolved argument position at every call site in
  the module, split by what the argument turned out to be:

  - `call_arg(caller, callee, arg_pos, value)` when the argument
    resolves to a literal atom string (e.g. `":my_pool"`), or to
    `"dynamic"` when resolution fails entirely.
  - `call_arg_forward(caller, callee, arg_pos, fwd_pos)` when the
    argument IS the caller's own parameter, forwarded through.
    `clientlib/interprocedural.dl` walks these backwards to propagate
    literal values through wrapper call chains.

  Only the first 4 arguments (positions 0–3) are resolved per call
  site. Module/table/server references sit in the first few positions
  in all OTP calling conventions; capping at 4 bounds fact volume to
  ~4× the number of call sites without losing useful data.

  Both remote calls (`call_ext`, `call_ext_only`, `call_ext_last`)
  and local calls (`call`, `call_only`, `call_last`) are captured.
  `apply` and `call_fun` are skipped — their callees and argument
  shapes are runtime-determined.
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers, only: [add_fact: 3, each_call: 3, resolve_to_arg_or_atom: 3]

  alias Argus.Pipeline.Normalize

  @max_args 4

  @impl true
  def relations,
    do: [
      :call_arg,
      :call_arg_forward
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    each_call(module_data, %{}, fn facts, ctx, {callee_mod, callee_func, arity} ->
      callee_id = Normalize.func_id(callee_mod, callee_func, arity)
      emit_call_args(facts, ctx, callee_id, arity)
    end)
  end

  defp emit_call_args(facts, ctx, callee_id, arity) do
    limit = min(arity, @max_args)

    if limit == 0 do
      facts
    else
      Enum.reduce(0..(limit - 1), facts, fn pos, acc ->
        # No call-site instruction ID: it renumbered on every edit and no
        # rule ever bound it (see Argus.Schema). Callers reason about which
        # FUNCTION passes which argument, not which instruction does.
        emit_arg(acc, ctx, callee_id, pos)
      end)
    end
  end

  # A forwarded parameter goes to its own relation with a real number
  # column rather than into call_arg's value column as `"arg:N"`. The
  # string encoding forced Datalog to decode it with the PARTIAL functor
  # `to_number`, guarded only by a sibling conjunct that Souffle is free to
  # schedule second — see Argus.Schema's call_arg_forward docs.
  defp emit_arg(facts, ctx, callee_id, pos) do
    case resolve_to_arg_or_atom(ctx.instrs, ctx.idx, {:x, pos}) do
      {:arg, n} ->
        add_fact(facts, :call_arg_forward, [
          ctx.func_id,
          callee_id,
          to_string(pos),
          to_string(n)
        ])

      {:atom, str} ->
        add_fact(facts, :call_arg, [ctx.func_id, callee_id, to_string(pos), str])

      :dynamic ->
        add_fact(facts, :call_arg, [ctx.func_id, callee_id, to_string(pos), "dynamic"])
    end
  end
end
