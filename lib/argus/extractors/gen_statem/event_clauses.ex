defmodule Argus.Extractors.GenStatem.EventClauses do
  @moduledoc """
  What event types a gen_statem callback discriminates on, and whether it
  has a catch-all.

  A state function `state(EventType, Content, Data)` and the
  `handle_event(EventType, Content, State, Data)` callback both receive
  the event type first, in `{x, 0}`. The clause heads are what the
  runtime's messages are matched against, so two questions about them are
  worth answering from the bytecode:

  - which event types does this callback have a clause for at all? A
    `{:timeout, ms, content}` action arms an event of type `:timeout`; a
    module that arms one and has no clause with `:timeout` first has a
    timer that fires into a crash. Postgrex's SimpleConnection wrote the
    handler as `handle_event(:info, :timeout, ...)` and pinged nothing.
  - does it accept an `:info` event with any content? A gen_statem in
    `state_functions` mode is only as robust as its least defensive state,
    and a state without an `:info` catch-all dies on the first stray
    message it sees while in that state.

  ## Reading the dispatch

  Clause selection compiles to tests whose failure branch is either the
  next clause's label or the function's own `func_info` label (raise
  FunctionClauseError). A catch-all for some register set is a path from
  the dispatch to a body that passes the success branch only of tests on
  those registers, and takes failure branches freely — a failed test on
  the content is just "not this clause", and the clause we are looking
  for is the one after it.

  So: for the `:info` catch-all, start where a test has just established
  `{x, 0} == :info` and allow success on `{x, 0}` only; for the total
  catch-all, start at the entry and allow success on nothing. Guards fall
  out correctly, since a guarded clause tests a register and its failure
  goes to `func_info`.

  ## Answers

  `analyse/1` returns the event types some clause head compares the first
  argument to (tagged tuples as `"{call}"`, `"{timeout}"`), whether some
  clause accepts `:info` with any content, and whether some clause accepts
  any event at all. `Argus.Extractors.GenStatem` emits them as
  `statem_event_clause`, `statem_info_catchall` and `statem_event_catchall`.
  """

  @x0 {:x, 0}

  @type t :: %{
          event_types: [String.t()],
          info_catchall?: boolean(),
          event_catchall?: boolean()
        }

  @doc """
  Reads one callback's clause heads. The caller turns the answer into
  facts; this module only walks bytecode.
  """
  @spec analyse([tuple()]) :: t()
  def analyse(instrs) do
    indexed = Enum.with_index(instrs)
    by_idx = Map.new(indexed, fn {instr, idx} -> {idx, instr} end)
    labels = Map.new(for {{:label, l}, idx} <- indexed, do: {l, idx})
    func_info = func_info_label(instrs)
    cfg = %{by_idx: by_idx, labels: labels, func_info: func_info, len: length(instrs)}

    %{
      event_types: instrs |> Enum.flat_map(&event_types_in/1) |> Enum.uniq(),
      info_catchall?: reaches_body?(info_entries(instrs, labels), [@x0], cfg),
      event_catchall?: reaches_body?([entry_index(instrs)], [], cfg)
    }
  end

  # ── Event types ──────────────────────────────────────────────────────

  defp event_types_in({:test, :is_eq_exact, _f, [a, b]}) do
    case {reg(a), reg(b)} do
      {@x0, _} -> atom_type(b)
      {_, @x0} -> atom_type(a)
      _ -> []
    end
  end

  defp event_types_in({:test, :is_tagged_tuple, _f, [src, _arity, {:atom, tag}]}) do
    if reg(src) == @x0, do: ["{#{tag}}"], else: []
  end

  defp event_types_in({:select_val, src, _fail, {:list, entries}}) do
    if reg(src) == @x0, do: for({:atom, a} <- entries, do: to_string(a)), else: []
  end

  defp event_types_in(_instr), do: []

  defp atom_type({:atom, a}), do: [to_string(a)]
  defp atom_type(_other), do: []

  # ── Catch-all walk ───────────────────────────────────────────────────

  # Where execution continues once `{x, 0} == :info` has been
  # established: after an is_eq_exact against :info, or at the label
  # select_val pairs with :info.
  defp info_entries(instrs, labels) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:test, :is_eq_exact, _f, [a, b]}, idx} ->
        if {reg(a), b} == {@x0, {:atom, :info}} or {a, reg(b)} == {{:atom, :info}, @x0},
          do: [idx + 1],
          else: []

      {{:select_val, src, _fail, {:list, entries}}, _idx} ->
        if reg(src) == @x0, do: info_targets(entries, labels), else: []

      _ ->
        []
    end)
  end

  defp info_targets([{:atom, :info}, {:f, l} | rest], labels),
    do: List.wrap(Map.get(labels, l)) ++ info_targets(rest, labels)

  defp info_targets([_value, _target | rest], labels), do: info_targets(rest, labels)
  defp info_targets(_other, _labels), do: []

  defp reaches_body?(starts, allowed, cfg), do: walk(starts, allowed, cfg, MapSet.new())

  defp walk([], _allowed, _cfg, _seen), do: false

  defp walk([idx | rest], allowed, cfg, seen) do
    cond do
      is_nil(idx) or idx >= cfg.len or MapSet.member?(seen, idx) ->
        walk(rest, allowed, cfg, seen)

      true ->
        seen = MapSet.put(seen, idx)

        case step(Map.fetch!(cfg.by_idx, idx), idx, allowed, cfg) do
          :body -> true
          next -> walk(next ++ rest, allowed, cfg, seen)
        end
    end
  end

  # Where a walk may go from one instruction. Tests are the whole story:
  # the success branch is passable only when every register the test
  # reads is one the caller allows, and the failure branch is passable
  # unless it raises FunctionClauseError.
  defp step(:return, _idx, _allowed, _cfg), do: :body
  defp step({:call_only, _, _}, _idx, _allowed, _cfg), do: :body
  defp step({:call_last, _, _, _}, _idx, _allowed, _cfg), do: :body
  defp step({:call_ext_only, _, _}, _idx, _allowed, _cfg), do: :body
  defp step({:call_ext_last, _, _, _}, _idx, _allowed, _cfg), do: :body
  defp step({:apply_last, _, _}, _idx, _allowed, _cfg), do: :body
  defp step({:wait, _}, _idx, _allowed, _cfg), do: :body
  defp step({:func_info, _, _, _}, _idx, _allowed, _cfg), do: []
  defp step({:badmatch, _}, _idx, _allowed, _cfg), do: []
  defp step({:case_end, _}, _idx, _allowed, _cfg), do: []
  defp step(:if_end, _idx, _allowed, _cfg), do: []
  defp step({:jump, {:f, l}}, _idx, _allowed, cfg), do: List.wrap(Map.get(cfg.labels, l))

  defp step({:test, _name, {:f, fail}, args}, idx, allowed, cfg) do
    success = if regs_in(args) |> Enum.all?(&(&1 in allowed)), do: [idx + 1], else: []
    success ++ failure(fail, cfg)
  end

  defp step({:test, _name, {:f, fail}, src, _fields}, idx, allowed, cfg) do
    success = if regs_in(src) |> Enum.all?(&(&1 in allowed)), do: [idx + 1], else: []
    success ++ failure(fail, cfg)
  end

  defp step({:select_val, src, {:f, fail}, {:list, entries}}, _idx, allowed, cfg) do
    targets = if reg(src) in allowed, do: select_targets(entries, cfg), else: []
    targets ++ failure(fail, cfg)
  end

  defp step({:select_tuple_arity, src, {:f, fail}, {:list, entries}}, _idx, allowed, cfg) do
    targets = if reg(src) in allowed, do: select_targets(entries, cfg), else: []
    targets ++ failure(fail, cfg)
  end

  defp step(_instr, idx, _allowed, _cfg), do: [idx + 1]

  defp failure(fail, cfg) do
    if fail == cfg.func_info, do: [], else: List.wrap(Map.get(cfg.labels, fail))
  end

  defp select_targets(entries, cfg) do
    for {:f, l} <- entries, target = Map.get(cfg.labels, l), do: target
  end

  # ── Registers ────────────────────────────────────────────────────────

  defp reg({:tr, r, _type}), do: reg(r)
  defp reg({:x, _} = r), do: r
  defp reg({:y, _} = r), do: r
  defp reg(_other), do: nil

  defp regs_in(term) when is_list(term), do: Enum.flat_map(term, &regs_in/1)

  defp regs_in(term) when is_tuple(term) do
    case reg(term) do
      nil -> term |> Tuple.to_list() |> Enum.flat_map(&regs_in/1)
      r -> [r]
    end
  end

  defp regs_in(_term), do: []

  # ── Function layout ──────────────────────────────────────────────────

  defp func_info_label(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> nil
      0 -> nil
      idx -> with {:label, l} <- Enum.at(instrs, idx - 1), do: l, else: (_ -> nil)
    end
  end

  defp entry_index(instrs) do
    case Enum.find_index(instrs, &match?({:func_info, _, _, _}, &1)) do
      nil -> 0
      idx -> idx + 1
    end
  end
end
