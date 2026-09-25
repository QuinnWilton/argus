defmodule Argus.Extractors.ParamFlow.Bounded do
  @moduledoc """
  Which registers hold a value from a set the program wrote down, at an
  instruction: a value compared equal to a literal on every path there,
  or found in a literal list.

  `String.to_atom(dir)` makes an atom of whatever it is handed, and one
  handed request data can fill the atom table. Not when the function only
  gets there with `dir` equal to one of a few literals: a clause head or a
  guard (`when dir in ["backwards", "forwards"]`, which compiles to
  `is_eq_exact` tests), a `case` arm, or a membership test against a list
  the program wrote — `if bin in @allowed`, `:lists.member(bin, [...])`,
  `Enum.member?(@allowed, bin)` — on the branch where it holds. The value
  is then one of a bounded set however it was derived, and a sink's
  argument that is is not unbounded input.

  A membership test against a list the function takes as a parameter
  bounds the value only where every caller hands a literal list: hexpm's
  `safe_to_atom(bin, allowed)`, whose callers pass `@sort_params`. Such a
  bound is `{:param, q}`, and the rule asks the callers (`literal_lists/4`
  says which calls pass one).

  A forward dataflow over the function's control-flow graph, meeting on
  every edge into a block (a register is bounded where it is bounded on
  every way in). The state follows values through the registers as
  `Argus.Instr.carry/2` does, and keeps which registers hold the same
  value (`groups`), so a test on one copy bounds the copy saved on the
  stack before it. What it does not follow stays unbounded: the quiet
  direction for a sanitizer, since an unbounded argument keeps its
  finding.
  """

  alias Argus.Cfg.Function, as: CfgFunction
  alias Argus.Extractor.Helpers
  alias Argus.Instr

  @typedoc "Why a value is bounded: always, or when the caller's parameter `q` is a literal list."
  @type bound :: :always | {:param, non_neg_integer()}

  @typep reg :: {:x | :y, non_neg_integer()}

  @typedoc false
  @type state :: %{
          bounded: %{reg() => bound()},
          lists: %{reg() => bound()},
          groups: [[reg()]],
          pending: %{reg() => {[reg()], bound()}}
        }

  # The membership tests: {module, function, arity} => {element position,
  # list position}.
  @members %{
    {:lists, :member, 2} => {0, 1},
    {Enum, :member?, 2} => {1, 0}
  }

  @doc """
  The state before each instruction at `idxs` in the function: `%{idx =>
  %{reg => bound}}`, the bounded registers there. An index the analysis
  does not reach (an unreachable block) maps to no bound.
  """
  @spec at(CfgFunction.t(), [tuple()], non_neg_integer(), [non_neg_integer()]) ::
          %{non_neg_integer() => %{reg() => bound()}}
  def at(%CfgFunction{} = fun, instrs, arity, idxs) do
    states_at(fun, instrs, arity, idxs, & &1.bounded)
  end

  @doc """
  The literal lists at `idxs`: `%{idx => %{reg => bound}}`, the registers
  holding a list the program wrote (`:always`) or the function's own
  list parameter (`{:param, q}`) before each instruction.
  """
  @spec literal_lists(CfgFunction.t(), [tuple()], non_neg_integer(), [non_neg_integer()]) ::
          %{non_neg_integer() => %{reg() => bound()}}
  def literal_lists(%CfgFunction{} = fun, instrs, arity, idxs) do
    states_at(fun, instrs, arity, idxs, & &1.lists)
  end

  defp states_at(_fun, _instrs, _arity, [], _pick), do: %{}

  defp states_at(fun, instrs, arity, idxs, pick) do
    tuple = List.to_tuple(instrs)
    ins = solve(fun, tuple, entry_state(arity))

    Map.new(idxs, fn idx ->
      case CfgFunction.block_at(fun, idx) do
        %{id: id, range: {first, _last}} ->
          case Map.fetch(ins, id) do
            {:ok, state} ->
              state = Enum.reduce(first..(idx - 1)//1, state, &step(elem(tuple, &1), &2))
              {idx, pick.(state)}

            :error ->
              {idx, %{}}
          end

        nil ->
          {idx, %{}}
      end
    end)
  end

  defp entry_state(arity) do
    %{
      bounded: %{},
      lists: Map.new(0..(arity - 1)//1, &{{:x, &1}, {:param, &1}}),
      groups: [],
      pending: %{}
    }
  end

  # ── The fixpoint ─────────────────────────────────────────────────────

  # A block's state on entry, for every block reached: the meet of the
  # states on the edges into it.
  defp solve(fun, tuple, entry) do
    iterate([fun.entry], %{fun.entry => entry}, fun, tuple)
  end

  defp iterate([], ins, _fun, _tuple), do: ins

  defp iterate([id | rest], ins, fun, tuple) do
    %{range: {first, last}} = block = Map.fetch!(fun.blocks, id)
    state = Enum.reduce(first..(last - 1)//1, Map.fetch!(ins, id), &step(elem(tuple, &1), &2))

    {ins, changed} =
      block
      |> out_states(elem(tuple, last), state, fun)
      |> Enum.reduce({ins, []}, fn {succ, out}, {ins, changed} ->
        case Map.fetch(ins, succ) do
          :error ->
            {Map.put(ins, succ, out), [succ | changed]}

          {:ok, old} ->
            new = meet(old, out)
            if new == old, do: {ins, changed}, else: {Map.put(ins, succ, new), [succ | changed]}
        end
      end)

    iterate(rest ++ Enum.reject(Enum.reverse(changed), &(&1 in rest)), ins, fun, tuple)
  end

  # The state on each edge out of a block, by successor block: a test's
  # pass and fail edges narrow differently, and so does each select arm.
  # Two edges into one block (a select's arms to one label, a test whose
  # fail label is the next block) meet there.
  defp out_states(block, instr, state, fun) do
    after_instr = step(instr, state)

    block.succs
    |> Enum.map(fn {succ, kind} ->
      {succ, edge_state(instr, kind, succ, state, after_instr, fun)}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {succ, [first | rest]} -> {succ, Enum.reduce(rest, first, &meet(&2, &1))} end)
  end

  defp edge_state({:test, op, _fail, [a, b]}, kind, _succ, _state, after_instr, _fun)
       when op in [:is_eq_exact, :is_eq, :is_ne_exact, :is_ne] and
              kind in [:branch_pass, :branch_fail] do
    equal? = op in [:is_eq_exact, :is_eq] == (kind == :branch_pass)
    if equal?, do: narrow_eq(after_instr, a, b), else: narrow_ne(after_instr, a, b)
  end

  # A test that fails writes nothing (a bs_start_match's context only
  # exists on its pass edge).
  defp edge_state({:test, _op, _fail, _args}, :branch_fail, _succ, state, _after, _fun), do: state

  defp edge_state(
         {:test, _op, _fail, _live, _args, _dst},
         :branch_fail,
         _succ,
         state,
         _after,
         _fun
       ),
       do: state

  defp edge_state(
         {:select_val, src, {:f, _}, {:list, pairs}},
         kind,
         succ,
         _state,
         after_instr,
         fun
       ) do
    arms = for [value, {:f, l}] <- Enum.chunk_every(pairs, 2), do: {value, label_block(fun, l)}

    case kind do
      {:select_arm, _} ->
        arms
        |> Enum.filter(&(elem(&1, 1) == succ))
        |> Enum.map(fn {value, _} -> narrow_eq(after_instr, src, value) end)
        |> case do
          [] -> after_instr
          [first | rest] -> Enum.reduce(rest, first, &meet(&2, &1))
        end

      :select_fail ->
        narrow_default(after_instr, src, Enum.map(arms, &elem(&1, 0)))

      _other ->
        after_instr
    end
  end

  defp edge_state(_instr, _kind, _succ, _state, after_instr, _fun), do: after_instr

  defp label_block(fun, label), do: Map.get(fun.labels, label)

  # ── One instruction ──────────────────────────────────────────────────

  @doc false
  @spec step(tuple() | atom(), state()) :: state()
  def step(instr, state) do
    state_before = state
    member = member_call(instr, state)
    groups = carry_groups(instr, state.groups)

    state = %{
      state
      | bounded: carry_map(instr, state.bounded),
        lists: carry_map(instr, state.lists),
        groups: groups,
        pending: carry_pending(instr, state.pending)
    }

    state
    |> put_constant(instr)
    |> put_made_of_bounded(instr, state_before)
    |> put_member(member, instr)
    |> put_comparison(instr)
  end

  # Every register a group's value is copied into joins it; a register a
  # copy reads that is in no group starts one.
  defp carry_groups(instr, groups) do
    sources =
      for dst <- Instr.defs(instr),
          src = Instr.copy_source(instr, dst),
          register?(src),
          not Enum.any?(groups, &(src in &1)),
          do: [src]

    (groups ++ sources)
    |> Enum.map(&Enum.sort(Instr.carry(instr, &1)))
    |> Enum.filter(&match?([_, _ | _], &1))
    |> Enum.uniq()
  end

  defp carry_map(instr, map) do
    Enum.reduce(map, %{}, fn {reg, bound}, acc ->
      Enum.reduce(Instr.carry(instr, [reg]), acc, &Map.put_new(&2, &1, bound))
    end)
  end

  defp carry_pending(instr, pending) do
    Enum.reduce(pending, %{}, fn {reg, {holders, bound}}, acc ->
      holders = Instr.carry(instr, holders)

      case {Instr.carry(instr, [reg]), holders} do
        {_, []} -> acc
        {regs, holders} -> Enum.reduce(regs, acc, &Map.put(&2, &1, {Enum.sort(holders), bound}))
      end
    end)
  end

  # A constant moved into a register is one value; a literal list is a
  # list the program wrote.
  defp put_constant(state, {op, src, dst}) when op in [:move, :fmove] do
    if register?(Instr.register(src)) do
      state
    else
      dst = Instr.register(dst)
      state = %{state | bounded: Map.put(state.bounded, dst, :always)}

      if list_literal?(src),
        do: %{state | lists: Map.put(state.lists, dst, :always)},
        else: state
    end
  end

  defp put_constant(state, _instr), do: state

  # A value built only of bounded values and literals — `"prefix_" <>
  # tab`, a tuple of two — is one of a bounded set too. Not a call's
  # result, which may be anything, nor a copy's, which carry handles.
  defp put_made_of_bounded(state, instr, before) do
    uses = Enum.filter(Instr.uses(instr), &register?/1)
    defs = Instr.defs(instr)

    cond do
      defs == [] or uses == [] or Instr.call?(instr) or copy?(instr) ->
        state

      Enum.all?(uses, &(Map.get(before.bounded, &1) == :always)) ->
        %{state | bounded: Enum.reduce(defs, state.bounded, &Map.put(&2, &1, :always))}

      true ->
        state
    end
  end

  defp copy?(instr), do: Enum.any?(Instr.defs(instr), &(Instr.copy_source(instr, &1) != nil))

  defp list_literal?(nil), do: true
  defp list_literal?({:literal, list}) when is_list(list), do: true
  defp list_literal?(_operand), do: false

  # What a membership call is asked, before the call destroys it: the
  # registers holding the element that outlive the call, and the list's
  # bound. The call's boolean lands in x0.
  defp member_call(instr, state) do
    with {:ok, mod, fun, arity} <- Helpers.match_remote_call(instr),
         {:ok, {elem_pos, list_pos}} <- Map.fetch(@members, {mod, fun, arity}),
         {:ok, bound} <- Map.fetch(state.lists, {:x, list_pos}) do
      holders = holders(state, {:x, elem_pos})
      {Enum.sort(Instr.carry(instr, holders)), bound}
    else
      _ -> nil
    end
  end

  defp put_member(state, nil, _instr), do: state
  defp put_member(state, {[], _bound}, _instr), do: state

  defp put_member(state, entry, instr) do
    if Instr.tail_call?(instr),
      do: state,
      else: %{state | pending: Map.put(state.pending, {:x, 0}, entry)}
  end

  # `x == lit` as a value: the boolean a later test branches on.
  defp put_comparison(state, {:bif, op, _fail, [a, b], dst}) when op in [:"=:=", :==] do
    case register_and_literal(a, b) do
      {:ok, reg} ->
        holders = holders(state, reg)
        %{state | pending: Map.put(state.pending, Instr.register(dst), {holders, :always})}

      :error ->
        state
    end
  end

  defp put_comparison(state, _instr), do: state

  # ── Narrowing on an edge ─────────────────────────────────────────────

  # `a` equals `b` on this edge: a register equal to a literal holds one
  # value, and a membership result equal to `true` bounds its element.
  defp narrow_eq(state, a, b) do
    case register_and_literal(a, b) do
      {:ok, reg} ->
        state
        |> bound(holders(state, reg), :always)
        |> settle(reg, literal_of(a, b) == true)

      :error ->
        state
    end
  end

  # `a` differs from `b`: a membership result that is not `false` (nor
  # `nil`, which Elixir's `if` tests too) is `true`.
  defp narrow_ne(state, a, b) do
    case register_and_literal(a, b) do
      {:ok, reg} -> settle(state, reg, literal_of(a, b) in [false, nil])
      :error -> state
    end
  end

  # The default of a select on a membership result whose arms are only
  # `false` and `nil`: Elixir's `if` taking its truthy branch.
  defp narrow_default(state, src, values) do
    literals = Enum.map(values, &literal_value/1)

    if literals != [] and Enum.all?(literals, &(&1 in [false, nil])),
      do: settle(state, Instr.register(src), true),
      else: state
  end

  defp settle(state, reg, true) do
    case Map.fetch(state.pending, reg) do
      {:ok, {holders, bound}} -> bound(state, holders, bound)
      :error -> state
    end
  end

  defp settle(state, _reg, false), do: state

  defp bound(state, regs, bound) do
    bounded =
      Enum.reduce(regs, state.bounded, fn reg, acc ->
        Map.update(acc, reg, bound, &stronger(&1, bound))
      end)

    %{state | bounded: bounded}
  end

  defp stronger(:always, _bound), do: :always
  defp stronger(_bound, :always), do: :always
  defp stronger(old, _new), do: old

  # A register and the registers in its group: every register holding its
  # value here.
  defp holders(state, reg) do
    reg = Instr.register(reg)
    Enum.find(state.groups, [reg], &(reg in &1))
  end

  defp register_and_literal(a, b) do
    {a, b} = {Instr.register(a), Instr.register(b)}

    cond do
      register?(a) and not register?(b) -> {:ok, a}
      register?(b) and not register?(a) -> {:ok, b}
      true -> :error
    end
  end

  defp literal_of(a, b) do
    if register?(Instr.register(a)), do: literal_value(b), else: literal_value(a)
  end

  defp literal_value({:atom, a}), do: a
  defp literal_value({:literal, v}), do: v
  defp literal_value({:integer, i}), do: i
  defp literal_value(nil), do: []
  defp literal_value(_operand), do: :unknown

  defp register?({kind, n}) when kind in [:x, :y] and is_integer(n), do: true
  defp register?(_operand), do: false

  # ── The meet ─────────────────────────────────────────────────────────

  # What holds on every way in: a register bounded (or a list, or a
  # membership result) on each, with the weaker bound; groups whose
  # registers agree on each.
  defp meet(a, b) do
    %{
      bounded: meet_bounds(a.bounded, b.bounded),
      lists: meet_bounds(a.lists, b.lists),
      groups: meet_groups(a.groups, b.groups),
      pending: meet_pending(a.pending, b.pending)
    }
  end

  defp meet_pending(a, b) do
    for {reg, {holders, bound}} <- a,
        {:ok, {holders2, ^bound}} <- [Map.fetch(b, reg)],
        common = Enum.sort(holders -- (holders -- holders2)),
        common != [],
        into: %{},
        do: {reg, {common, bound}}
  end

  defp meet_bounds(a, b) do
    for {reg, bound} <- a,
        {:ok, bound2} <- [Map.fetch(b, reg)],
        weaker = weaker(bound, bound2),
        weaker != nil,
        into: %{},
        do: {reg, weaker}
  end

  defp weaker(same, same), do: same
  defp weaker(:always, other), do: other
  defp weaker(other, :always), do: other
  defp weaker(_one, _another), do: nil

  defp meet_groups(a, b) do
    for g1 <- a,
        g2 <- b,
        common = Enum.sort(g1 -- (g1 -- g2)),
        match?([_, _ | _], common),
        uniq: true,
        do: common
  end
end
