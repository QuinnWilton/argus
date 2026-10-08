defmodule Argus.Extractors.CallArgs do
  @moduledoc """
  Call-site argument extractor.

  Emits one fact per resolved argument position at every call site in
  the module, split by what the argument turned out to be:

  - `call_arg(caller, callee, arg_pos, value)` when the argument
    resolves to a literal atom, binary or integer, spelled as
    `Argus.Extractor.Identity.key_identity/4` spells it (`":my_pool"`, `"\"users\""`,
    `"42"`), or to `"dynamic"` when resolution fails entirely.
  - `call_arg_forward(caller, callee, arg_pos, fwd_pos)` when the
    argument IS the caller's own parameter, forwarded through.
    `resolved_arg` in `clientlib/calls.dl` walks these backwards to propagate
    literal values through wrapper call chains.
  - `call_arg_field(caller, callee, arg_pos, key)` when the argument was
    read from a map under a literal key (`start_timer(ms, state.ref)`):
    which piece of the caller's state a helper is handed.
  - `call_arg_element(caller, callee, arg_pos, param_pos, index)` when
    the argument is element `index` of the caller's parameter
    (`elem(record, 1)`).
  - `call_arg_tuple(caller, callee, arg_pos, index, source, value)` for
    a tuple the caller builds as the argument: what its element `index`
    (0 or 1) is, in the vocabulary of `key_identity/4`.

  - `infinity_arg(caller, callee, arg_pos)` when the argument is the
    literal `:infinity`, at any position: a timeout a wrapper hands on.
  - `mfa_arg(id, caller, callee, pos, mod, target)` when a call into a
    function of the program is handed a literal module, a literal
    function name and a list of known length at three positions in a
    row: the MFA a wrapper around an rpc runs, by site.

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

  import Argus.Extractor.Helpers, only: [each_call: 3]
  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Extractor.Identity, only: [key_identity: 3, tuple_element_identity: 5]
  import Argus.Extractor.Resolve, only: [resolve_register: 3, resolve_to_arg_or_atom: 3]

  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Runtime
  alias Argus.InstrId
  @max_args 4
  @tuple_elements 2

  @impl true
  def relations,
    do: [
      :call_arg,
      :call_arg_element,
      :call_arg_field,
      :call_arg_forward,
      :call_arg_tuple,
      :infinity_arg,
      :mfa_arg
    ]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    each_call(module_data, %{}, fn facts, ctx, {callee_mod, callee_func, arity} ->
      callee_id = InstrId.func_id(callee_mod, callee_func, arity)

      facts
      |> emit_call_args(ctx, callee_id, arity)
      |> emit_mfa_args(ctx, callee_mod, callee_id, arity)
    end)
  end

  # A module, a function name and an argument list, literal and in a row,
  # handed to a function of the program: `Rpc.call(node, M, :f, [a, b])`.
  # Every position, not the first four alone: an rpc wrapper's node and
  # options come first and last.
  defp emit_mfa_args(facts, ctx, callee_mod, callee_id, arity) do
    if arity < 3 or Runtime.module?(callee_mod) do
      facts
    else
      Enum.reduce(0..(arity - 3)//1, facts, fn pos, acc ->
        with {:ok, mod} when is_atom(mod) and mod not in [nil, :dynamic] <-
               resolve_register(ctx.instrs, ctx.idx, {:x, pos}),
             {:ok, fun} when is_atom(fun) and fun not in [nil, :dynamic] <-
               resolve_register(ctx.instrs, ctx.idx, {:x, pos + 1}),
             n when is_integer(n) <- Resolve.list_length(ctx.instrs, ctx.idx, {:x, pos + 2}) do
          add_fact(acc, :mfa_arg, [
            InstrId.mint(ctx.func_id, ctx.idx),
            ctx.func_id,
            callee_id,
            to_string(pos),
            inspect(mod),
            InstrId.func_id(mod, fun, n)
          ])
        else
          _ -> acc
        end
      end)
    end
  end

  defp emit_call_args(facts, ctx, callee_id, arity) do
    limit = min(arity, @max_args)

    facts =
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

    infinity_args(facts, ctx, callee_id, limit, arity)
  end

  # :infinity past the fourth argument, where call_arg stops: a timeout
  # is often the fifth (`:rpc.call/5`, a wrapper around it). Within the
  # first four, emit_arg records it as it resolves the atom.
  defp infinity_args(facts, _ctx, _callee_id, from, arity) when from >= arity, do: facts

  defp infinity_args(facts, ctx, callee_id, from, arity) do
    Enum.reduce(from..(arity - 1)//1, facts, fn pos, acc ->
      case resolve_register(ctx.instrs, ctx.idx, {:x, pos}) do
        {:ok, :infinity} -> infinity_arg(acc, ctx, callee_id, pos)
        _ -> acc
      end
    end)
  end

  defp infinity_arg(facts, ctx, callee_id, pos),
    do: add_fact(facts, :infinity_arg, [ctx.func_id, callee_id, to_string(pos)])

  # A forwarded parameter goes to its own relation with a real number
  # column rather than into call_arg's value column as `"arg:N"`. The
  # string encoding forced Datalog to decode it with the PARTIAL functor
  # `to_number`, guarded only by a sibling conjunct that a planner is free to
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

      {:atom, ":infinity" = str} ->
        facts
        |> add_fact(:call_arg, [ctx.func_id, callee_id, to_string(pos), str])
        |> infinity_arg(ctx, callee_id, pos)

      {:atom, str} ->
        add_fact(facts, :call_arg, [ctx.func_id, callee_id, to_string(pos), str])

      :dynamic ->
        # A literal binary or integer, spelled as the key identities the
        # rules join it with are: a key handed to a helper is the same key.
        case key_identity(ctx.instrs, ctx.idx, {:x, pos}) do
          {"literal", value} ->
            add_fact(facts, :call_arg, [ctx.func_id, callee_id, to_string(pos), value])

          identity ->
            facts
            |> add_fact(:call_arg, [ctx.func_id, callee_id, to_string(pos), "dynamic"])
            |> dynamic_arg(ctx, callee_id, pos, identity)
            |> tuple_arg(ctx, callee_id, pos)
        end
    end
  end

  defp dynamic_arg(facts, ctx, callee_id, pos, {"field", key}),
    do: add_fact(facts, :call_arg_field, [ctx.func_id, callee_id, to_string(pos), key])

  defp dynamic_arg(facts, ctx, callee_id, pos, {"element " <> n, param}),
    do: add_fact(facts, :call_arg_element, [ctx.func_id, callee_id, to_string(pos), param, n])

  defp dynamic_arg(facts, _ctx, _callee_id, _pos, _identity), do: facts

  # A tuple built for the call: what its first two elements are — a
  # record's table and key, an ETS object's key — for a callee that names
  # them as elements of its parameter.
  defp tuple_arg(facts, ctx, callee_id, pos) do
    Enum.reduce(0..(@tuple_elements - 1), facts, fn n, acc ->
      case tuple_element_identity(ctx.instrs, ctx.idx, {:x, pos}, n, nil) do
        {"dynamic", _} ->
          acc

        {source, value} ->
          add_fact(acc, :call_arg_tuple, [
            ctx.func_id,
            callee_id,
            to_string(pos),
            to_string(n),
            source,
            value
          ])
      end
    end)
  end
end
