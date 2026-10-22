defmodule Argus.Extractors.ErrorHandling.ErrorBranch do
  @moduledoc """
  The calls a function makes only once a value matched an error: on the
  edge a test takes for `:error` or `{:error, _}` (`{:error, _} ->
  retry(state)`, a `with`'s `else` clause for it), and everything that
  edge dominates. Such a call handles a failure: a timer armed there is a
  retry, armed again only while the work keeps failing, not a loop's
  every tick.

  The edge is the pass edge of an `is_tagged_tuple` or `is_eq_exact` test
  against `:error`, the fail edge of an `is_ne_exact` one, or a
  `select_val` arm for `:error`. Its target must have no other way in:
  a block a success path also enters runs on success too.
  """

  alias Argus.Cfg.{Block, Function}
  alias Argus.Instr

  @doc """
  The indices of the call instructions (tail calls included) of `fun`'s
  `instrs` that run only on an error branch.
  """
  @spec calls(Function.t() | nil, tuple()) :: [non_neg_integer()]
  def calls(nil, _instrs), do: []

  def calls(%Function{} = fun, instrs) do
    case error_entries(fun, instrs) do
      [] ->
        []

      entries ->
        for {id, %Block{range: {first, last}}} <- fun.blocks,
            Enum.any?(entries, &Function.dominates?(fun, &1, id)),
            idx <- first..last,
            instr = elem(instrs, idx),
            Instr.call?(instr) or Instr.tail_call?(instr),
            do: idx
    end
  end

  # The blocks entered only along an error edge.
  defp error_entries(fun, instrs) do
    for {_id, %Block{range: {_first, last}, succs: succs}} <- fun.blocks,
        {to, kind} <- succs,
        error_edge?(elem(instrs, last), kind),
        %Block{preds: [_only]} <- [Map.fetch!(fun.blocks, to)],
        uniq: true,
        do: to
  end

  defp error_edge?({:test, :is_tagged_tuple, _fail, [_src, _arity, {:atom, :error}]}, kind),
    do: kind == :branch_pass

  defp error_edge?({:test, op, _fail, [a, b]}, kind) when op in [:is_eq_exact, :is_eq],
    do: kind == :branch_pass and error_atom?(a, b)

  defp error_edge?({:test, op, _fail, [a, b]}, kind) when op in [:is_ne_exact, :is_ne],
    do: kind == :branch_fail and error_atom?(a, b)

  defp error_edge?({:select_val, _src, _fail, {:list, _pairs}}, kind),
    do: kind == {:select_arm, inspect(:error)}

  defp error_edge?(_instr, _kind), do: false

  defp error_atom?(a, b), do: {:atom, :error} in [a, b]
end
