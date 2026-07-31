defmodule Argus.Extractors.CallArgs do
  @moduledoc """
  Call-site argument extractor.

  Emits `call_arg(id, caller, callee, arg_pos, value)` facts for
  every call site in the module, recording the resolved argument
  value at each position. Values are one of:

  - A literal atom string (e.g. `":my_pool"`) when the argument
    resolves to a static atom.
  - `"arg:N"` when the argument is the caller's own parameter N,
    indicating forwarding. Datalog rules in
    `clientlib/interprocedural.dl` use this to propagate literal
    values transitively through wrapper call chains.
  - `"dynamic"` when resolution fails entirely.

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

  import Argus.Extractor.Helpers,
    only: [
      add_fact: 3,
      match_remote_call: 1,
      match_local_call: 1,
      resolve_to_arg_or_atom: 3,
      scan_functions: 4
    ]

  alias Argus.Pipeline.Normalize

  @max_args 4

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    scan_functions(module_data.module, module_data.functions, %{}, fn facts, ctx, instr ->
      case match_call(instr) do
        {:ok, callee_mod, callee_func, arity} ->
          callee_id = Normalize.func_id(callee_mod, callee_func, arity)
          emit_call_args(facts, ctx, callee_id, arity)

        :none ->
          facts
      end
    end)
  end

  # Match both remote and local calls, returning a unified
  # {:ok, mod, func, arity} or :none.
  defp match_call(instr) do
    case match_remote_call(instr) do
      {:ok, _, _, _} = match -> match
      :none -> match_local_call(instr)
    end
  end

  defp emit_call_args(facts, ctx, callee_id, arity) do
    limit = min(arity, @max_args)

    if limit == 0 do
      facts
    else
      Enum.reduce(0..(limit - 1), facts, fn pos, acc ->
        value = resolve_arg_value(ctx.instrs, ctx.idx, {:x, pos})
        # No call-site instruction ID: it renumbered on every edit and no
        # rule ever bound it (see Argus.Schema). Callers reason about which
        # FUNCTION passes which argument, not which instruction does.
        add_fact(acc, :call_arg, [ctx.func_id, callee_id, to_string(pos), value])
      end)
    end
  end

  defp resolve_arg_value(instrs, idx, register) do
    case resolve_to_arg_or_atom(instrs, idx, register) do
      {:atom, str} -> str
      {:arg, n} -> "arg:#{n}"
      :dynamic -> "dynamic"
    end
  end
end
