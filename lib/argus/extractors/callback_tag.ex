defmodule Argus.Extractors.CallbackTag do
  @moduledoc """
  The message tags a `handle_call/3` or `handle_cast/2` discriminates on,
  and whether it has a catch-all.

  The server half of a GenServer's contract. The client half — which tag a
  wrapper actually sends — is not extracted here: it is a join over
  `tuple_literal`/`literal_value`, `def_use` and `remote_call`, which is
  what makes it sound. An earlier version scanned backwards from the call
  for the last write to `{x,1}` and attributed a stale one, reporting
  `:amqp_channel` as casting `:ok` when the write was really
  `gen_server:reply(From, ok)`.

  Tags are over-approximated: every atom compared anywhere in the body
  counts, without tracking which register held it. Consumers ask whether a
  tag is NOT handled, so over-approximating suppresses findings rather than
  inventing them.

  ## Emitted facts

  - `callback_tag(func, callback, tag)` — an atom the callback discriminates on
  - `callback_total(func, callback)` — it has a catch-all, so no tag can fail
  """

  @behaviour Argus.Extractor

  alias Argus.InstrId

  import Argus.Extractor.Helpers, only: [add_fact: 3]

  @callbacks %{{:handle_call, 3} => "handle_call", {:handle_cast, 2} => "handle_cast"}

  @impl true
  def extract(%{module: mod, functions: functions}) do
    Enum.reduce(functions, %{}, fn {:function, name, arity, _entry, instrs}, acc ->
      case Map.fetch(@callbacks, {name, arity}) do
        :error ->
          acc

        {:ok, callback} ->
          func_id = InstrId.func_id(mod, name, arity)

          acc
          |> emit_tags(func_id, callback, instrs)
          |> emit_total(func_id, callback, instrs)
      end
    end)
  end

  defp emit_tags(facts, func_id, callback, instrs) do
    instrs
    |> Enum.flat_map(&compared_atoms/1)
    |> Enum.uniq()
    |> Enum.reduce(facts, &add_fact(&2, :callback_tag, [func_id, callback, inspect(&1)]))
  end

  defp compared_atoms({:test, :is_eq_exact, _f, args}), do: atoms_in(args)
  defp compared_atoms({:test, :is_tagged_tuple, _f, args}), do: atoms_in(args)
  defp compared_atoms({:select_val, _s, _f, {:list, entries}}), do: atoms_in(entries)
  defp compared_atoms(_instr), do: []

  defp atoms_in(list) when is_list(list), do: for({:atom, a} <- list, is_atom(a), do: a)
  defp atoms_in(_other), do: []

  # A multi-clause function raises FunctionClauseError by jumping to its own
  # func_info label, so it accepts everything exactly when nothing branches
  # there. Guards fall out correctly: a guarded catch-all compiles to a test
  # whose failure branch is that label, and is therefore not a catch-all.
  defp emit_total(facts, func_id, callback, instrs) do
    case func_info_label(instrs) do
      nil ->
        facts

      label ->
        if Enum.any?(instrs, &(label in branch_targets(&1))),
          do: facts,
          else: add_fact(facts, :callback_total, [func_id, callback])
    end
  end

  defp func_info_label(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> nil
      0 -> nil
      idx -> with {:label, l} <- Enum.at(instrs, idx - 1), do: l, else: (_ -> nil)
    end
  end

  defp branch_targets(instr), do: collect_f(instr, [])
  defp collect_f({:f, l}, acc) when is_integer(l) and l > 0, do: [l | acc]

  defp collect_f(t, acc) when is_tuple(t),
    do: t |> Tuple.to_list() |> Enum.reduce(acc, &collect_f/2)

  defp collect_f(t, acc) when is_list(t), do: Enum.reduce(t, acc, &collect_f/2)
  defp collect_f(_t, acc), do: acc
end
