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

  ## Integer ranges

  `when n in 1..8` compiles to `is_integer(n)`, `n >= 1` and `8 >= n`
  tests, and so does `is_integer(n) and n >= 1 and n <= 8`: on the
  edge where they all hold, `n` is one of eight integers, as bounded as
  a literal list. Both ends and the integer test are needed — `n >= 1
  and n <= 8` alone admits every float between — and the range must be
  narrow: at most 1,024 values, a thousandth of the default atom
  table, since `n in 1..100_000` is bounded only in name. A pure
  conversion of a bounded value (`Integer.to_string/1`,
  `String.Chars.to_string/1`, ...) is bounded too: the image of a finite
  set is finite, so `:"phrase_\#{n}"` makes one of eight atoms.

  ## How many

  A bound says which values it admits — the literals themselves, an
  integer range, or, for a value made of others, how many — and the
  limit is on that count, not on each piece: a value made of several
  bounded ones is one of the product of their counts (`"tile_\#{x}_\#{y}"`
  with `x` and `y` each in `0..1023` is one of 1,048,576 — the whole
  default table — and is not bounded). Where two ways into a block meet,
  literals join as a set (`r in ~w(a b c d)` compiles to four tests, and
  their four edges admit four values), ranges as their hull, and
  anything else as the sum of the two counts, unless both ways carry the
  same description: the same values, as a loop's back edge carries what
  its entry did.

  ## Atoms made of atoms

  A value that is an atom — tested by `is_atom/1`, or read out of one by
  `Atom.to_string/1`, `atom_to_list/1` and the like, which fail on
  anything else — is one of the atoms that already exist, and an atom
  made of it and of literals (`:"\#{name}_id"`, Erlang's
  `list_to_atom(atom_to_list(Tab) ++ "_sup")`) is one more per existing
  atom, not one per string an outside party can send. Such a value is
  bounded `{:atoms, n}` (`n` values per atom), which only an atom sink
  takes as bounded — a deserialization's question is what its bytes are,
  not how many there can be — and only where the atoms that exist are
  not the caller's choice. They are when the atom came out of
  `String.to_existing_atom/1` (the next request names the atom this one
  made: `:name_desc`, then `:name_desc_desc`, ...), when a request's data
  reaches the sink, and when the site's own atoms come back to it (a
  recursion that names each child after its parent). This module cannot
  see those; `unsafe_input.dl` asks them of the `"atoms"` row
  (`Argus.Extractors.ParamFlow` marks an argument made of an existing
  atom's lookup `sink_arg_chosen`/`call_arg_chosen`).

  A path on which the value is made of atoms and one on which it is in a
  list the caller passes admit neither bound on both: they meet to none.
  """

  alias Argus.Cfg.Function, as: CfgFunction
  alias Argus.Extractor.Helpers
  alias Argus.Instr

  @typedoc """
  Why a value is bounded: one of the values `desc` describes, which the
  program wrote (`{:values, desc}`); made of atoms that exist and of
  values the program wrote, `desc` counting those per atom (`{:atoms,
  desc}`); or one of a list the caller's parameter `q` holds, where every
  caller passes a literal list (`{:param, q}`).
  """
  @type bound :: {:values, desc()} | {:atoms, desc()} | {:param, non_neg_integer()}

  @typedoc """
  Which values: these literals (`{:set, sorted}`), the integers from `lo`
  to `hi`, an existing atom (`:atom`, one per atom), or `n` values made
  of others, told apart from another `n` by `tag`.
  """
  @type desc ::
          {:set, [term()]}
          | {:range, integer(), integer()}
          | :atom
          | {:many, pos_integer(), non_neg_integer()}

  @typep reg :: {:x | :y, non_neg_integer()}

  # What the tests on a path have said of an integer: whether it is one,
  # and its least and greatest value (`nil` while unknown).
  @typep range :: {boolean(), integer() | nil, integer() | nil}

  @typedoc false
  @type state :: %{
          bounded: %{reg() => bound()},
          lists: %{reg() => bound()},
          groups: [[reg()]],
          pending: %{reg() => {[reg()], bound()}},
          ranges: %{reg() => range()}
        }

  # The most values a bound admits: a thousandth of the default atom
  # table, for an integer range and for a product of bounded pieces alike.
  @range_limit 1024

  # Conversions whose result is a function of their arguments alone: a
  # bounded argument gives a bounded result.
  @conversions MapSet.new([
                 {String.Chars, :to_string, 1},
                 {Integer, :to_string, 1},
                 {Integer, :to_string, 2},
                 {Integer, :to_charlist, 1},
                 {Integer, :to_charlist, 2},
                 {:erlang, :integer_to_binary, 1},
                 {:erlang, :integer_to_binary, 2},
                 {:erlang, :integer_to_list, 1},
                 {:erlang, :integer_to_list, 2},
                 {:erlang, :binary_to_list, 1},
                 {:erlang, :list_to_binary, 1},
                 {:erlang, :iolist_to_binary, 1},
                 {:erlang, :++, 2},
                 {:lists, :append, 2},
                 {:lists, :concat, 1},
                 {:lists, :flatten, 1},
                 {List, :to_string, 1},
                 {String, :upcase, 1},
                 {String, :downcase, 1},
                 {Macro, :underscore, 1},
                 {Macro, :camelize, 1}
               ])

  # What an atom's name is read out with: whatever the argument, the
  # result is an existing atom's name, since anything else raises.
  @atom_names MapSet.new([
                {Atom, :to_string, 1},
                {Atom, :to_charlist, 1},
                {:erlang, :atom_to_binary, 1},
                {:erlang, :atom_to_binary, 2},
                {:erlang, :atom_to_list, 1}
              ])

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
  holding a list the program wrote (`{:values, n}`) or the function's own
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
      pending: %{},
      ranges: %{}
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

  # An order test against an integer literal narrows the register's
  # range on both edges: `is_ge` holds on its pass edge and fails into
  # `is_lt`'s, and the other way round.
  defp edge_state({:test, op, _fail, [a, b]}, kind, _succ, _state, after_instr, _fun)
       when op in [:is_ge, :is_lt] and kind in [:branch_pass, :branch_fail] do
    narrow_order(after_instr, a, b, op == :is_ge == (kind == :branch_pass))
  end

  defp edge_state(
         {:test, :is_integer, _fail, [a]},
         :branch_pass,
         _succ,
         _state,
         after_instr,
         _fun
       ) do
    narrow_range(after_instr, a, fn {_int, lo, hi} -> {true, lo, hi} end)
  end

  defp edge_state({:test, :is_atom, _fail, [a]}, :branch_pass, _succ, _state, after_instr, _fun) do
    reg = Instr.register(a)

    if register?(reg),
      do: bound(after_instr, holders(after_instr, reg), {:atoms, :atom}),
      else: after_instr
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
        |> Enum.map(&elem(&1, 0))
        |> case do
          [] -> after_instr
          [value] -> narrow_eq(after_instr, src, value)
          values -> narrow_arms(after_instr, src, values)
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
    converted = conversion(instr, state)
    groups = carry_groups(instr, state.groups)

    state = %{
      state
      | bounded: carry_map(instr, state.bounded),
        lists: carry_map(instr, state.lists),
        groups: groups,
        pending: carry_pending(instr, state.pending),
        ranges: carry_map(instr, state.ranges)
    }

    state
    |> put_constant(instr)
    |> put_made_of_bounded(instr, state_before)
    |> put_conversion(converted, instr)
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
      state = %{state | bounded: Map.put(state.bounded, dst, {:values, {:set, [element(src)]}})}

      case list_literal(src) do
        {:ok, list} -> %{state | lists: Map.put(state.lists, dst, list_bound(list))}
        :error -> state
      end
    end
  end

  defp put_constant(state, _instr), do: state

  # A value built only of bounded values and literals — `"prefix_" <>
  # tab`, a tuple of two — is one of a bounded set too. Not a call's
  # result, which may be anything, nor a copy's, which carry handles.
  defp put_made_of_bounded(state, instr, before) do
    uses = Enum.filter(Instr.uses(instr), &register?/1)
    defs = Instr.defs(instr)

    if defs == [] or uses == [] or Instr.call?(instr) or copy?(instr) do
      state
    else
      case combine(Enum.map(uses, &Map.get(before.bounded, &1)), instr) do
        nil -> state
        bound -> %{state | bounded: Enum.reduce(defs, state.bounded, &Map.put(&2, &1, bound))}
      end
    end
  end

  # What a value made of values with these bounds is, by the operation
  # `how` that makes it: one of the product of their counts, made of atoms
  # when any piece is, and unbounded past the limit or when a piece is
  # unbounded or the caller's list.
  defp combine([_ | _] = bounds, how) do
    if Enum.all?(bounds, &match?({kind, _} when kind in [:values, :atoms], &1)) do
      count = Enum.reduce(bounds, 1, fn {_kind, desc}, acc -> count(desc) * acc end)
      kind = if Enum.any?(bounds, &match?({:atoms, _}, &1)), do: :atoms, else: :values
      counted(kind, {:many, count, :erlang.phash2({how, bounds})})
    end
  end

  defp combine([], _how), do: nil

  defp counted(kind, desc), do: if(count(desc) <= @range_limit, do: {kind, desc})

  defp count({:set, values}), do: length(values)
  defp count({:range, lo, hi}), do: hi - lo + 1
  defp count(:atom), do: 1
  defp count({:many, n, _tag}), do: n

  # The values of either way in: literals as a set, integers as the range
  # that holds both, anything else as the sum of the counts. The tag of a
  # sum is the pair's, whichever way round it was met.
  defp join(same, same), do: same
  defp join({:set, a}, {:set, b}), do: {:set, :lists.umerge(a, b)}
  defp join({:range, lo1, hi1}, {:range, lo2, hi2}), do: {:range, min(lo1, lo2), max(hi1, hi2)}

  defp join({:set, values} = set, {:range, lo, hi} = range) do
    if Enum.all?(values, &is_integer/1),
      do: {:range, min(lo, Enum.min(values)), max(hi, Enum.max(values))},
      else: summed(set, range)
  end

  defp join({:range, _, _} = range, {:set, _} = set), do: join(set, range)
  defp join(one, other), do: summed(one, other)

  defp summed(one, other) do
    {:many, count(one) + count(other), :erlang.phash2(Enum.sort([one, other]))}
  end

  # The result of a conversion call, asked before the call destroys its
  # arguments: an atom's name whatever the argument, or a pure conversion
  # of bounded arguments.
  defp conversion(instr, state) do
    with {:ok, mod, fun, arity} <- Helpers.match_remote_call(instr) do
      cond do
        MapSet.member?(@atom_names, {mod, fun, arity}) ->
          {:atoms, :atom}

        MapSet.member?(@conversions, {mod, fun, arity}) ->
          combine(for(i <- 0..(arity - 1)//1, do: Map.get(state.bounded, {:x, i})), instr)

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  # The call's result lands in x0, unless the call is the function's last.
  defp put_conversion(state, nil, _instr), do: state

  defp put_conversion(state, bound, instr) do
    if Instr.tail_call?(instr),
      do: state,
      else: %{state | bounded: Map.put(state.bounded, {:x, 0}, bound)}
  end

  defp copy?(instr), do: Enum.any?(Instr.defs(instr), &(Instr.copy_source(instr, &1) != nil))

  defp list_literal(nil), do: {:ok, []}
  defp list_literal({:literal, list}) when is_list(list), do: {:ok, list}
  defp list_literal(_operand), do: :error

  # A member of a literal list is one of its elements: as many values as
  # the list has (an improper literal counts its cells). The program wrote
  # every one, so a long list is still a bound; the limit is on what
  # values made of it multiply to.
  defp list_bound(list), do: {:values, {:set, list |> cells([]) |> Enum.sort() |> Enum.dedup()}}

  defp cells([value | rest], acc), do: cells(rest, [value | acc])
  defp cells([], acc), do: acc
  defp cells(tail, acc), do: [tail | acc]

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
        bound = {:values, {:set, [element_of(a, b)]}}
        %{state | pending: Map.put(state.pending, Instr.register(dst), {holders, bound})}

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
        |> bound(holders(state, reg), {:values, {:set, [element_of(a, b)]}})
        |> settle(reg, literal_of(a, b) == true)

      :error ->
        state
    end
  end

  # Several arms of a select reach one block: the register is one of the
  # values they name. A membership result is settled by one arm only, so
  # several settle nothing (a `true` arm and a `false` arm to one block
  # say nothing of the element).
  defp narrow_arms(state, src, values) do
    reg = Instr.register(src)

    if register?(reg),
      do: bound(state, holders(state, reg), {:values, arm_values(values)}),
      else: state
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

  defp arm_values(values),
    do: {:set, values |> Enum.map(&element/1) |> Enum.sort() |> Enum.dedup()}

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

  # Both hold: the fewer values, and a count over a condition.
  defp stronger({kind, a}, {kind, b}) when kind in [:values, :atoms],
    do: if(count(b) < count(a), do: {kind, b}, else: {kind, a})

  defp stronger({:values, _} = values, _bound), do: values
  defp stronger(_bound, {:values, _} = values), do: values
  defp stronger({:atoms, _} = atoms, _bound), do: atoms
  defp stronger(_bound, {:atoms, _} = atoms), do: atoms
  defp stronger(old, _new), do: old

  # `a >= b` (`ge?`) or `a < b` holds on this edge: a register compared
  # with an integer literal gains an end.
  defp narrow_order(state, a, b, ge?) do
    case order_ends(Instr.register(a), Instr.register(b), ge?) do
      {:ok, reg, lo, hi} -> narrow_range(state, reg, &at_least(&1, lo, hi))
      :error -> state
    end
  end

  # The ends `reg >= k`, `reg < k`, `k >= reg` and `k < reg` give an
  # integer.
  defp order_ends(reg, {:integer, k}, true) when is_integer(k), do: ends(reg, k, nil)
  defp order_ends(reg, {:integer, k}, false) when is_integer(k), do: ends(reg, nil, k - 1)
  defp order_ends({:integer, k}, reg, true) when is_integer(k), do: ends(reg, nil, k)
  defp order_ends({:integer, k}, reg, false) when is_integer(k), do: ends(reg, k + 1, nil)
  defp order_ends(_a, _b, _ge?), do: :error

  defp ends(reg, lo, hi), do: if(register?(reg), do: {:ok, reg, lo, hi}, else: :error)

  defp at_least({int, lo, hi}, new_lo, new_hi),
    do: {int, tighter(lo, new_lo, &max/2), tighter(hi, new_hi, &min/2)}

  defp tighter(nil, new, _pick), do: new
  defp tighter(old, nil, _pick), do: old
  defp tighter(old, new, pick), do: pick.(old, new)

  # Every register holding the value learns the same of it; one whose
  # range is now an integer's between two close ends is bounded.
  defp narrow_range(state, reg, update) do
    reg = Instr.register(reg)

    if register?(reg) do
      regs = holders(state, reg)
      range = update.(Map.get(state.ranges, reg, {false, nil, nil}))
      state = %{state | ranges: Enum.reduce(regs, state.ranges, &Map.put(&2, &1, range))}

      case range do
        {true, lo, hi} when is_integer(lo) and is_integer(hi) and hi - lo < @range_limit ->
          bound(state, regs, {:values, {:range, lo, max(hi, lo)}})

        _ ->
          state
      end
    else
      state
    end
  end

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

  # A literal operand as a member of a set of values: its value, or the
  # operand itself when its kind is not read (two such operands are equal
  # only when they are the same literal).
  defp element_of(a, b), do: if(register?(Instr.register(a)), do: element(b), else: element(a))

  defp element(operand) do
    case literal_value(operand) do
      :unknown -> {:operand, operand}
      value -> value
    end
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
      pending: meet_pending(a.pending, b.pending),
      ranges: meet_ranges(a.ranges, b.ranges)
    }
  end

  # An integer on every way in, between the least of the lower ends and
  # the greatest of the upper ones; an end one way lacks is unknown.
  defp meet_ranges(a, b) do
    for {reg, {int1, lo1, hi1}} <- a,
        {:ok, {int2, lo2, hi2}} <- [Map.fetch(b, reg)],
        range = {int1 and int2, both(lo1, lo2, &min/2), both(hi1, hi2, &max/2)},
        range != {false, nil, nil},
        into: %{},
        do: {reg, range}
  end

  defp both(nil, _other, _pick), do: nil
  defp both(_one, nil, _pick), do: nil
  defp both(one, other, pick), do: pick.(one, other)

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

  # One of two ways in: the values of both (join/2); made of atoms if
  # either is; a caller's list where the other way is the program's own
  # values. Atoms one way and a caller's list the other admit neither
  # bound.
  defp weaker(same, same), do: same

  defp weaker({kind1, a}, {kind2, b})
       when kind1 in [:values, :atoms] and kind2 in [:values, :atoms] do
    kind = if :atoms in [kind1, kind2], do: :atoms, else: :values
    counted(kind, join(a, b))
  end

  defp weaker({:values, _}, {:param, _} = param), do: param
  defp weaker({:param, _} = param, {:values, _}), do: param
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
