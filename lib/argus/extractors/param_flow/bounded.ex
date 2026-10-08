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
  `Enum.member?(@allowed, bin)`, or `Enum.__in__/2` from Elixir 1.20 —
  on the branch where it holds. The value
  is then one of a bounded set however it was derived, and a sink's
  argument that is is not unbounded input.

  A membership test against a list the function takes as a parameter
  bounds the value only where every caller hands a literal list: hexpm's
  `safe_to_atom(bin, allowed)`, whose callers pass `@sort_params`. Such a
  bound is `{:param, q}`, and the rule asks the callers whether each
  passes one (`Argus.Extractors.ParamFlow`'s `call_arg_allowlist`).

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
  call on bounded values (`Integer.to_string/1`, `String.replace_prefix/3`,
  `List.last/1`, `String.Chars.to_string/1` on builtin inputs, ...) is
  bounded too: the image of a finite set under a function of its
  arguments alone is finite, so `:"phrase_\#{n}"` makes one of eight
  atoms. A fun is never bounded, so such a call runs no code but its own.

  A lookup in a literal table (`Enum.at/2,3`, `Enum.fetch!/2`, or
  `:lists.nth/2`) also has a finite result vocabulary. `Enum.at` includes
  its default in the bound; a dynamic fallback or runtime-supplied table
  remains unbounded. Finite table members stay finite through atom-name
  conversion instead of becoming the weaker existing-atom bound.

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

  When this join loses correlations, atom sinks get a bounded fallback
  that keeps guard alternatives separate. A tokenizer admitting a few
  three-character operators need not admit every combination of their
  characters. The fallback uses the same transfers, collapses excess
  alternatives to their conservative join, and proves nothing if its
  fixed instruction-step budget is exhausted.

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
  alias Argus.Extractor.Terms
  alias Argus.Extractors.SecurityValues.Binary
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

  @type bounds :: %{reg() => bound()}
  @type return_bounds :: %{mfa() => bound()}

  @typep reg :: {:x | :y, non_neg_integer()}

  # What the tests on a path have said of an integer: whether it is one,
  # and its least and greatest value (`nil` while unknown).
  @typep range :: {boolean(), integer() | nil, integer() | nil}

  @typedoc false
  @type state :: %{
          bounded: %{reg() => bound()},
          binaries: MapSet.t(reg()),
          lists: %{reg() => bound()},
          groups: [[reg()]],
          pending: %{reg() => {[reg()], bound()}},
          ranges: %{reg() => range()},
          returns: %{tuple() => bound()}
        }

  # The most values a bound admits: a thousandth of the default atom
  # table, for an integer range and for a product of bounded pieces alike.
  @range_limit 1024

  # Exact alternatives retain list shape as well as cardinality. Limit the
  # total retained list cells too, including nested heads, so a CFG cycle
  # cannot keep growing a small set of increasingly large literal lists.
  @literal_cell_limit 4096

  # Preserve a few alternatives when joining their independent character
  # domains would invent combinations the guards never allow. Exhaustion
  # loses a proof, never a path.
  @partition_limit 32
  @partition_steps 50_000

  # Modules each of whose functions computes its result from its arguments
  # alone: it reads no state, dispatches no protocol, and runs no code but
  # its own and the funs it is handed. A call into one with every argument
  # bounded has a bounded result, since a bounded value is never a fun
  # (`fun_free?/1`) and so the call runs only the module's own code:
  # `String.replace_prefix/3`, `List.last/1`, `:lists.flatten/1`. Not
  # `:erlang`, whose BIFs read the node's state (`system_info/1`) or build
  # funs of any code (`make_fun/3`), nor `:binary`, which can answer how a
  # binary is stored (`referenced_byte_size/1`), nor Enum, Map or Keyword,
  # which dispatch Enumerable and Collectable on a struct.
  @pure_modules MapSet.new([
                  String,
                  :string,
                  :unicode,
                  Integer,
                  Float,
                  Atom,
                  List,
                  :lists,
                  Tuple,
                  Base,
                  :base64
                ])

  # Functions outside those modules whose result is a function of their
  # arguments alone. `Module.split/1` takes an `"Elixir."` binary as well
  # as an atom, so it reads no existing atom's name: its result is bounded
  # by its argument's bound, not by the atoms that exist.
  @conversions MapSet.new([
                 {:erlang, :integer_to_binary, 1},
                 {:erlang, :integer_to_binary, 2},
                 {:erlang, :integer_to_list, 1},
                 {:erlang, :integer_to_list, 2},
                 {:erlang, :binary_to_list, 1},
                 {:erlang, :list_to_binary, 1},
                 {:erlang, :iolist_to_binary, 1},
                 {:erlang, :++, 2},
                 {Macro, :underscore, 1},
                 {Macro, :camelize, 1},
                 {Macro, :unescape_string, 1},
                 {Module, :split, 1}
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
  # list position}. Elixir compiles `x in list` over a list known only at
  # run time to Enum.member?/2 up to 1.19, and to Enum.__in__/2, the
  # element first, from 1.20.
  @members %{
    {:lists, :member, 2} => {0, 1},
    {Enum, :member?, 2} => {1, 0},
    {Enum, :__in__, 2} => {0, 1}
  }

  @doc """
  The state before each instruction at `idxs` in the function: `%{idx =>
  %{reg => bound}}`, the bounded registers there. An index the analysis
  does not reach (an unreachable block) maps to no bound.
  """
  @spec at(
          CfgFunction.t(),
          [Instr.instr()],
          arity(),
          [non_neg_integer()],
          bounds(),
          return_bounds()
        ) :: %{non_neg_integer() => bounds()}
  def at(%CfgFunction{} = fun, instrs, arity, idxs, entry, returns) do
    states_at(fun, instrs, arity, idxs, entry, returns)
  end

  @doc false
  @spec common_entries(nonempty_list(bounds())) :: bounds()
  def common_entries([head | tail]), do: Enum.reduce(tail, head, &meet_bounds/2)

  @doc """
  A bounded fallback for sinks whose independently joined registers lose
  correlations between guard alternatives. It uses the same transfers as
  `at/4`, retaining at most 32 incoming states per block before joining all
  of them. Only blocks that can reach the requested sink are considered.
  A fixed instruction-step budget returns no proof if exhausted.
  """
  @spec correlated_at(
          CfgFunction.t(),
          [Instr.instr()],
          arity(),
          [non_neg_integer()],
          bounds(),
          return_bounds()
        ) :: %{non_neg_integer() => bounds()}
  def correlated_at(fun, instrs, arity, idxs, entry, returns) do
    tuple = List.to_tuple(instrs)

    Map.new(idxs, fn idx ->
      block = CfgFunction.block_at(fun, idx)
      allowed = ancestors([block.id], fun.blocks, %{})
      ins = %{fun.entry => {false, [entry_state(arity, entry, returns)]}}

      bounds =
        case partitioned([fun.entry], ins, fun, tuple, allowed, @partition_steps) do
          {:ok, ins} -> partition_bounds(Map.get(ins, block.id), block.range, idx, tuple)
          :exhausted -> %{}
        end

      {idx, bounds}
    end)
  end

  defp ancestors([], _blocks, seen), do: seen

  defp ancestors([id | rest], blocks, seen) do
    if Map.has_key?(seen, id) do
      ancestors(rest, blocks, seen)
    else
      preds = Enum.map(Map.fetch!(blocks, id).preds, &elem(&1, 0))
      ancestors(preds ++ rest, blocks, Map.put(seen, id, true))
    end
  end

  defp partitioned([], ins, _fun, _tuple, _allowed, _budget), do: {:ok, ins}
  defp partitioned(_queue, _ins, _fun, _tuple, _allowed, budget) when budget < 0, do: :exhausted

  defp partitioned([id | rest], ins, fun, tuple, allowed, budget) do
    %{range: {first, last}} = block = Map.fetch!(fun.blocks, id)
    {_collapsed, states} = Map.fetch!(ins, id)
    budget = budget - (last - first + 1) * length(states)

    if budget < 0 do
      :exhausted
    else
      outputs =
        Enum.flat_map(states, fn state ->
          state = Enum.reduce(first..(last - 1)//1, state, &step(elem(tuple, &1), &2))
          instr = elem(tuple, last)
          block = %{block | succs: Enum.filter(block.succs, &possible_edge?(instr, &1, state))}
          out_states(block, instr, state, fun)
        end)

      {ins, changed} =
        outputs
        |> Enum.filter(fn {succ, _state} -> Map.has_key?(allowed, succ) end)
        |> Enum.reduce({ins, []}, fn {succ, out}, {ins, changed} ->
          old = Map.get(ins, succ)
          new = add_partition(old, out)

          if old == new,
            do: {ins, changed},
            else: {Map.put(ins, succ, new), [succ | changed]}
        end)

      queue = rest ++ (changed |> Enum.uniq() |> Enum.sort() |> Enum.reject(&(&1 in rest)))
      partitioned(queue, ins, fun, tuple, allowed, budget)
    end
  end

  # A disjunct keeps exact literal information from earlier tests. Reject
  # an edge only when every value still represented contradicts it.
  defp possible_edge?({:test, op, _fail, [a, b]}, {_succ, kind}, state)
       when op in [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne] and
              kind in [:branch_pass, :branch_fail] do
    equal? = op in [:is_eq_exact, :is_eq] == (kind == :branch_pass)

    case {literal_options(a, state), literal_options(b, state)} do
      {{:ok, as}, {:ok, bs}} ->
        Enum.any?(as, fn a ->
          Enum.any?(bs, fn b ->
            # Keep exact-inequality edges conservatively feasible: a bound
            # establishes a finite vocabulary, not all refinements of the
            # value's type. Loose equality includes numeric equivalents.
            if equal?, do: a == b, else: op in [:is_eq_exact, :is_ne_exact] or a != b
          end)
        end)

      _ ->
        true
    end
  end

  defp possible_edge?(_instr, _edge, _state), do: true

  defp literal_options(operand, state) do
    case Map.get(state.bounded, Instr.register(operand)) do
      {:values, {:set, values}} -> {:ok, values}
      _ -> literal_option(operand)
    end
  end

  defp literal_option({:atom, value}), do: {:ok, [value]}
  defp literal_option({:integer, value}), do: {:ok, [value]}
  defp literal_option({:float, value}), do: {:ok, [value]}
  defp literal_option({:literal, value}), do: {:ok, [value]}
  defp literal_option(nil), do: {:ok, [[]]}
  defp literal_option(_operand), do: :unknown

  defp add_partition(nil, out), do: {false, [out]}
  defp add_partition({true, [old]}, out), do: {true, [meet(old, out)]}

  defp add_partition({false, old}, out) do
    states = Enum.sort(Enum.uniq([out | old]))

    if length(states) > @partition_limit,
      do: {true, [Enum.reduce(tl(states), hd(states), &meet/2)]},
      else: {false, states}
  end

  defp partition_bounds(nil, _range, _idx, _tuple), do: %{}

  defp partition_bounds({_collapsed, states}, {first, _last}, idx, tuple) do
    [head | tail] =
      Enum.map(states, fn state ->
        Enum.reduce(first..(idx - 1)//1, state, &step(elem(tuple, &1), &2)).bounded
      end)

    Enum.reduce(tail, head, &meet_bounds/2)
  end

  defp states_at(_fun, _instrs, _arity, [], _entry, _returns), do: %{}

  defp states_at(fun, instrs, arity, idxs, entry, returns) do
    tuple = List.to_tuple(instrs)
    ins = solve(fun, tuple, entry_state(arity, entry, returns))

    Map.new(idxs, fn idx ->
      case CfgFunction.block_at(fun, idx) do
        %{id: id, range: {first, _last}} ->
          case Map.fetch(ins, id) do
            {:ok, state} ->
              state = Enum.reduce(first..(idx - 1)//1, state, &step(elem(tuple, &1), &2))
              {idx, state.bounded}

            :error ->
              {idx, %{}}
          end

        nil ->
          {idx, %{}}
      end
    end)
  end

  defp entry_state(arity, bounded, returns) do
    %{
      bounded: bounded,
      binaries: MapSet.new(),
      lists: Map.new(0..(arity - 1)//1, &{{:x, &1}, {:param, &1}}),
      groups: [],
      pending: %{},
      ranges: %{},
      returns: returns
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

    if equal?,
      do: narrow_eq(after_instr, a, b, op in [:is_eq_exact, :is_ne_exact]),
      else: narrow_ne(after_instr, a, b)
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

  defp edge_state({:test, :is_binary, _fail, [a]}, :branch_pass, _succ, _state, after_instr, _fun) do
    binaries = Enum.reduce(holders(after_instr, a), after_instr.binaries, &MapSet.put(&2, &1))
    %{after_instr | binaries: binaries}
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
        binaries: Binary.step(instr, state.binaries),
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
  defp put_constant(state, {op, src, dst} = instr) when op in [:move, :fmove] do
    if register?(Instr.register(src)) or not fun_free?(instr) do
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
  defp put_made_of_bounded(state, {:put_list, head, tail, dst} = instr, before) do
    with {:ok, heads} <- literal_options(head, before),
         {:ok, tails} <- literal_options(tail, before),
         true <- length(heads) * length(tails) <= @range_limit,
         true <- list_expansion_fits?(heads, tails),
         true <- fun_free?(heads) and fun_free?(tails) do
      values = for head <- heads, tail <- tails, do: [head | tail]
      bound = {:values, {:set, exact_values(values)}}
      %{state | bounded: Map.put(state.bounded, Instr.register(dst), bound)}
    else
      _ -> put_combined(state, instr, before)
    end
  end

  defp put_made_of_bounded(state, instr, before), do: put_combined(state, instr, before)

  defp list_expansion_fits?(heads, tails) do
    with head_cells when is_integer(head_cells) <- list_cells_in(heads),
         tail_cells when is_integer(tail_cells) <- list_cells_in(tails) do
      length(heads) * length(tails) + head_cells * length(tails) +
        tail_cells * length(heads) <= @literal_cell_limit
    else
      _ -> false
    end
  end

  defp list_cells_in(values) do
    Enum.reduce_while(values, 0, fn value, cells ->
      case list_cells(value, @literal_cell_limit - cells) do
        remaining when is_integer(remaining) ->
          {:cont, @literal_cell_limit - remaining}

        :exhausted ->
          {:halt, :exhausted}
      end
    end)
  end

  defp list_cells([head | tail], remaining) when remaining > 0 do
    case list_cells(head, remaining - 1) do
      remaining when is_integer(remaining) -> list_cells(tail, remaining)
      :exhausted -> :exhausted
    end
  end

  defp list_cells([_head | _tail], _remaining), do: :exhausted
  defp list_cells(_other, remaining), do: remaining

  defp put_combined(state, instr, before) do
    uses = Enum.filter(Instr.uses(instr), &register?/1)
    defs = Instr.defs(instr)

    if defs == [] or uses == [] or Instr.call?(instr) or copy?(instr) or not fun_free?(instr) do
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
  defp join({:set, a}, {:set, b}), do: {:set, exact_values(a ++ b)}
  defp join(same, same), do: same
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
    target =
      case Helpers.match_remote_call(instr) do
        :none -> Helpers.match_local_call(instr)
        remote -> remote
      end

    with {:ok, mod, fun, arity} <- target do
      cond do
        Map.has_key?(state.returns, {mod, fun, arity}) ->
          Map.fetch!(state.returns, {mod, fun, arity})

        {mod, fun, arity} in [
          {Enum, :at, 2},
          {Enum, :at, 3},
          {Enum, :fetch!, 2},
          {:lists, :nth, 2}
        ] ->
          table_lookup(state, mod, fun, arity)

        {mod, fun, arity} == {String.Chars, :to_string, 1} ->
          stringify_builtin(state, instr)

        {mod, fun, arity} == {Enum, :reverse, 1} ->
          reverse_literal_lists(state, instr)

        MapSet.member?(@atom_names, {mod, fun, arity}) ->
          # Retain an explicitly finite atom table through atom_to_binary.
          # The general existing-atom bound is weaker and may be invalidated
          # when request data chooses from atoms created by previous calls.
          combine([Map.get(state.bounded, {:x, 0})], instr) || {:atoms, :atom}

        MapSet.member?(@conversions, {mod, fun, arity}) or MapSet.member?(@pure_modules, mod) ->
          combine(for(i <- 0..(arity - 1)//1, do: Map.get(state.bounded, {:x, i})), instr)

        true ->
          nil
      end
    else
      _ -> nil
    end
  end

  # Protocol implementations may consult state outside their input. Only
  # builtin inputs establish that to_string is a pure finite conversion.
  # The original atom bound arises from an atom guard or an atom-name BIF;
  # transformations of it have a different descriptor and stay unknown here.
  defp stringify_builtin(state, instr) do
    bound = Map.get(state.bounded, {:x, 0})

    pure? =
      case bound do
        {:atoms, :atom} -> true
        {:values, {:range, _lo, _hi}} -> true
        {:values, {:set, values}} -> Enum.all?(values, &builtin_string_value?/1)
        _ -> false
      end

    if pure? or MapSet.member?(state.binaries, {:x, 0}), do: combine([bound], instr)
  end

  defp builtin_string_value?(value)
       when is_atom(value) or is_number(value) or is_binary(value),
       do: true

  defp builtin_string_value?(value), do: proper_list?(value)

  # Enum dispatches arbitrary values through a user-defined Enumerable
  # implementation, whose output need not depend only on its argument. Its
  # proper-list branch is pure; retain that proof only for complete list
  # alternatives, including lists built from finite character selections.
  defp reverse_literal_lists(state, instr) do
    case Map.get(state.bounded, {:x, 0}) do
      {:values, {:set, values}} = bound ->
        if Enum.all?(values, &proper_list?/1), do: combine([bound], instr)

      _ ->
        nil
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_other), do: false

  # A fixed table bounds the selected data even when the index is arbitrary.
  # Enum.at can also return its default; an unknown default never proves safety.
  # Lists.nth/fetch! raise outside the table and therefore have no extra result.
  defp table_lookup(state, mod, fun, arity) do
    list_pos = if mod == :lists, do: 1, else: 0

    with {:values, _} = table <- Map.get(state.lists, {:x, list_pos}) do
      case {fun, arity} do
        {:at, 2} -> weaker(table, {:values, {:set, [nil]}})
        {:at, 3} -> weaker(table, Map.get(state.bounded, {:x, 2}))
        _ -> table
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

  # A bound describes data, never a fun: a fun's result is not a function
  # of the bounded values it is handed, since its code may read anything.
  # Neither a literal holding a fun nor a closure (`make_fun3`, whose
  # captures may all be bounded) is bounded, nor anything built of one,
  # which keeps a pure call's bounded arguments free of code to run.
  defp fun_free?({:make_fun3, _target, _index, _uniq, _dst, _env}), do: false
  defp fun_free?(term), do: not Terms.value_contains?(term, &is_function/1)

  defp copy?(instr), do: Enum.any?(Instr.defs(instr), &(Instr.copy_source(instr, &1) != nil))

  defp list_literal(nil), do: {:ok, []}
  defp list_literal({:literal, list}) when is_list(list), do: {:ok, list}
  defp list_literal(_operand), do: :error

  # A member of a literal list is one of its elements: as many values as
  # the list has (an improper literal counts its cells). The program wrote
  # every one, so a long list is still a bound; the limit is on what
  # values made of it multiply to.
  defp list_bound(list), do: {:values, {:set, list |> cells([]) |> exact_values()}}

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
    with {:ok, reg} <- register_and_literal(a, b),
         {:values, _} = bound <- equality_bound(element_of(a, b), op == :"=:=") do
      holders = holders(state, reg)
      %{state | pending: Map.put(state.pending, Instr.register(dst), {holders, bound})}
    else
      _ -> state
    end
  end

  defp put_comparison(state, _instr), do: state

  # ── Narrowing on an edge ─────────────────────────────────────────────

  # Equality with a literal establishes its complete equivalence class.
  # Loose numeric equality includes integer and floating representations;
  # composite numeric classes stay unknown instead of undercounting them.
  defp narrow_eq(state, a, b, exact? \\ true) do
    with {:ok, reg} <- register_and_literal(a, b),
         {:values, _} = value_bound <- equality_bound(element_of(a, b), exact?) do
      state
      |> bound(holders(state, reg), value_bound)
      |> settle(reg, literal_of(a, b) == true)
    else
      _ -> state
    end
  end

  defp equality_bound(value, true), do: if(fun_free?(value), do: {:values, {:set, [value]}})

  defp equality_bound(value, false) when is_number(value),
    do: {:values, {:set, exact_values(numeric_equivalents(value))}}

  defp equality_bound(value, false) do
    if fun_free?(value) and not Terms.value_contains?(value, &is_number/1),
      do: {:values, {:set, [value]}}
  end

  defp numeric_equivalents(value) when value == 0, do: [0, 0.0, -0.0]

  defp numeric_equivalents(value) when is_float(value) do
    integer = trunc(value)
    if value == integer, do: [integer, value], else: [value]
  end

  defp numeric_equivalents(value) when is_integer(value) do
    float = :erlang.float(value)
    if value == float, do: [value, float], else: [value]
  rescue
    ArgumentError -> [value]
  end

  # Erlang's sorted-set merge identifies 1 and 1.0; conversions distinguish
  # them. A deterministic binary tie-break also keeps either join order equal.
  defp exact_values(values) do
    values
    |> Enum.uniq()
    |> Enum.sort_by(fn value -> {value, :erlang.term_to_binary(value, [:deterministic])} end)
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
    do: {:set, values |> Enum.map(&element/1) |> exact_values()}

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
  defp literal_value({:float, f}), do: f
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
      binaries: MapSet.intersection(a.binaries, b.binaries),
      lists: meet_bounds(a.lists, b.lists),
      groups: meet_groups(a.groups, b.groups),
      pending: meet_pending(a.pending, b.pending),
      ranges: meet_ranges(a.ranges, b.ranges),
      returns: a.returns
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
