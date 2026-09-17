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

  alias Argus.Cfg.Function
  alias Argus.Cfg.Walk
  alias Argus.Extractor.Dispatch

  @x0 {:x, 0}

  @type t :: %{
          event_types: [String.t()],
          info_catchall?: boolean(),
          event_catchall?: boolean()
        }

  @doc """
  Reads one callback's clause heads. The caller turns the answer into
  facts; this module only walks bytecode, over the function's graph.
  Without a graph nothing is a catch-all.
  """
  @spec analyse(Function.t() | nil, [tuple()]) :: t()
  def analyse(fun, instrs) do
    labels = Dispatch.labels(instrs)
    func_info = Dispatch.func_info_label(instrs)

    %{
      event_types: Enum.uniq(Enum.flat_map(instrs, &event_types_in/1) ++ tagged_types(instrs)),
      info_catchall?:
        reaches_body?(
          fun,
          instrs,
          Dispatch.continuations_after(instrs, @x0, :info, labels),
          [@x0],
          func_info
        ),
      event_catchall?: reaches_body?(fun, instrs, [Dispatch.entry_index(instrs)], [], func_info)
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

  # A tuple head with a varying element, `{:timeout, name}` or
  # `{:call, from}`, compiles to is_tuple + test_arity + a
  # get_tuple_element of x0's first element into a scratch register and
  # an atom test on that register; is_tagged_tuple is the fused form
  # the compiler picks only sometimes.
  @tag_window 4

  defp tagged_types([{:get_tuple_element, src, 0, dst} | rest]) do
    if reg(src) == @x0,
      do: tag_tests(rest, reg(dst), @tag_window) ++ tagged_types(rest),
      else: tagged_types(rest)
  end

  defp tagged_types([_instr | rest]), do: tagged_types(rest)
  defp tagged_types([]), do: []

  defp tag_tests(_instrs, _dst, 0), do: []
  defp tag_tests([], _dst, _n), do: []
  defp tag_tests([{:label, _} | _], _dst, _n), do: []

  defp tag_tests([{:test, :is_eq_exact, _f, [a, b]} | _], dst, _n) do
    case {reg(a), reg(b)} do
      {^dst, _} -> tag_of(b)
      {_, ^dst} -> tag_of(a)
      _ -> []
    end
  end

  defp tag_tests([{:select_val, src, _fail, {:list, entries}} | _], dst, _n) do
    if reg(src) == dst, do: for({:atom, a} <- entries, do: "{#{a}}"), else: []
  end

  defp tag_tests([instr | rest], dst, n) do
    if dst in regs_in(instr), do: [], else: tag_tests(rest, dst, n - 1)
  end

  defp tag_of({:atom, a}), do: ["{#{a}}"]
  defp tag_of(_other), do: []

  defp atom_type({:atom, a}), do: [to_string(a)]
  # A fully-literal tagged tuple, `{:timeout, :backoff}`: the same type
  # is_tagged_tuple names when the tuple's other elements vary.
  defp atom_type({:literal, tuple}) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    case elem(tuple, 0) do
      tag when is_atom(tag) -> ["{#{tag}}"]
      _ -> []
    end
  end

  defp atom_type(_other), do: []

  # ── Catch-all walk ───────────────────────────────────────────────────

  # A body is reachable from the starting points passing the success
  # branch only of tests on allowed registers and taking failure
  # branches freely, unless the failure is the FunctionClauseError label.
  defp reaches_body?(nil, _instrs, _starts, _allowed, _func_info), do: false

  defp reaches_body?(fun, instrs, starts, allowed, func_info) do
    result =
      Walk.explore(fun, instrs, starts,
        on_instr: fn
          {:func_info, _, _, _}, _idx -> :prune
          :return, _idx -> {:halt, :body}
          {:call_only, _, _}, _idx -> {:halt, :body}
          {:call_last, _, _, _}, _idx -> {:halt, :body}
          {:call_ext_only, _, _}, _idx -> {:halt, :body}
          {:call_ext_last, _, _, _}, _idx -> {:halt, :body}
          {:apply_last, _, _}, _idx -> {:halt, :body}
          {:wait, _}, _idx -> {:halt, :body}
          _instr, _idx -> :continue
        end,
        follow?: &follow?(&1, &2, allowed, func_info)
      )

    match?({:halted, :body}, result)
  end

  defp follow?({:test, _, _, args}, :branch_pass, allowed, _fi),
    do: Enum.all?(regs_in(args), &(&1 in allowed))

  defp follow?({:test, _, _, src, _fields}, :branch_pass, allowed, _fi),
    do: Enum.all?(regs_in(src), &(&1 in allowed))

  defp follow?({:test, _, {:f, fail}, _}, :branch_fail, _allowed, fi), do: fail != fi
  defp follow?({:test, _, {:f, fail}, _, _}, :branch_fail, _allowed, fi), do: fail != fi

  defp follow?({op, src, _, _}, {:select_arm, _}, allowed, _fi)
       when op in [:select_val, :select_tuple_arity],
       do: reg(src) in allowed

  defp follow?({op, _, {:f, fail}, _}, :select_fail, _allowed, fi)
       when op in [:select_val, :select_tuple_arity],
       do: fail != fi

  defp follow?(_instr, _kind, _allowed, _fi), do: true

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
end
