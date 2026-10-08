defmodule Argus.Extractors.StateGate.Absent do
  @moduledoc """
  Where a function acquires something only when the store it keeps it in
  lacks the key: `case :maps.is_key(pid, state.monitors) of true -> ...;
  false -> monitor(pid) end`, `if not MapSet.member?(s.subs, topic), do:
  subscribe(topic)`, `[] = :ets.lookup(:owners, pid)` before a link.

  An *ask* is a membership test or a lookup of a key in a store: a field
  of one of the function's parameters (a map key, a record's position, as
  `returned_update` spells it) or a named ETS table. The asks read:

  - membership, absent when it answers `false`: `:maps.is_key/2`,
    `:erlang.is_map_key/2` (`Map.has_key?/2`), `MapSet.member?/2`,
    `:sets.is_element/2`, `:ordsets.is_element/2`, `:gb_sets.is_element/2`
    and `is_member/2`, `:lists.member/2`, `:lists.keymember/3`,
    `Enum.member?/2`, `Keyword.has_key?/2`, `:ets.member/2`;
  - lookups, absent when they answer the missing value: `Map.get/2`,
    `Keyword.get/2` (`nil`), `Map.get/3` and `:maps.get/3` (their default,
    when it is a literal atom), `:proplists.get_value/2` (`undefined`),
    `Map.fetch/2` and `:maps.find/2` (`:error`), `:lists.keyfind/3`
    (`false`), `:ets.lookup/2` (`[]`).

  A call (or send) is taken only when the store lacks the key when the
  walk that fixes the ask's answer at *absent* reaches it and the walk
  that fixes it at *present* does not: each test of the answer takes only
  the edges that value can take. The row names which of the site's
  arguments the ask's key is (the same writes reach both), so a rule can
  tell "monitors the pid it looked up" from "monitors something while
  some key is missing"; a site whose arguments are not the key has no
  row.
  """

  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.StateGate
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @typedoc "A row: the site's index, the parameter (-1 for a table), the store, the key's argument."
  @type row :: {non_neg_integer(), integer(), String.t(), non_neg_integer()}

  # {module, function, arity} => {key position, store position, absent}.
  @asks %{
    {:maps, :is_key, 2} => {0, 1, {:atom, false}},
    {MapSet, :member?, 2} => {1, 0, {:atom, false}},
    {:sets, :is_element, 2} => {0, 1, {:atom, false}},
    {:ordsets, :is_element, 2} => {0, 1, {:atom, false}},
    {:gb_sets, :is_element, 2} => {0, 1, {:atom, false}},
    {:gb_sets, :is_member, 2} => {0, 1, {:atom, false}},
    {:lists, :member, 2} => {0, 1, {:atom, false}},
    {:lists, :keymember, 3} => {0, 2, {:atom, false}},
    {Enum, :member?, 2} => {1, 0, {:atom, false}},
    {Keyword, :has_key?, 2} => {1, 0, {:atom, false}},
    {:ets, :member, 2} => {1, 0, {:atom, false}},
    {Map, :get, 2} => {1, 0, {:atom, nil}},
    {Keyword, :get, 2} => {1, 0, {:atom, nil}},
    {Map, :get, 3} => {1, 0, {:default, 2}},
    {:maps, :get, 3} => {0, 1, {:default, 2}},
    {:proplists, :get_value, 2} => {0, 1, {:atom, :undefined}},
    {Map, :fetch, 2} => {1, 0, {:atom, :error}},
    {:maps, :find, 2} => {0, 1, {:atom, :error}},
    {:lists, :keyfind, 3} => {0, 2, {:missing, false}},
    {:ets, :lookup, 2} => {1, 0, :empty_list}
  }

  @eq_ops [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]

  @doc "The rows of the function `instrs`, of `arity` parameters."
  @spec rows([Instr.instr()], non_neg_integer()) :: [row()]
  def rows(instrs, arity) do
    asks =
      for {instr, idx} <- Enum.with_index(instrs), ask <- ask(instrs, idx, instr, arity), do: ask

    if asks == [] do
      []
    else
      tuple = List.to_tuple(instrs)
      labels = Instr.labels(instrs)
      entry = Dispatch.entry_index(instrs)
      sites = for {instr, idx} <- Enum.with_index(instrs), site?(instr), do: idx

      asks
      |> Enum.flat_map(&gated(&1, instrs, tuple, labels, entry, sites))
      |> Enum.uniq()
      |> Enum.sort()
    end
  end

  # An ask at `idx`: its answer's register, its store, the key's operand,
  # and the answer when the key is absent.
  defp ask(instrs, idx, {:bif, :is_map_key, _fail, [key, map], dst}, arity),
    do: asked(instrs, idx, Instr.register(dst), key, map, {:atom, false}, arity)

  defp ask(instrs, idx, instr, arity) do
    with {:ok, mfa} <- remote(instr),
         {:ok, {key_at, store_at, absent}} <- Map.fetch(@asks, mfa),
         {:ok, absent} <- absent_value(instrs, idx, absent) do
      asked(instrs, idx, {:x, 0}, {:x, key_at}, {:x, store_at}, absent, arity)
    else
      _ -> []
    end
  end

  defp absent_value(_instrs, _idx, {:atom, _} = atom), do: {:ok, atom}
  defp absent_value(_instrs, _idx, {:missing, atom}), do: {:ok, {:missing, atom}}
  defp absent_value(_instrs, _idx, :empty_list), do: {:ok, :empty_list}

  defp absent_value(instrs, idx, {:default, at}) do
    case Resolve.resolve_register(instrs, idx, {:x, at}) do
      {:ok, atom} when atom in [nil, :undefined, false] -> {:ok, {:atom, atom}}
      _ -> :none
    end
  end

  defp asked(instrs, idx, answer, key, store_operand, absent, arity) do
    for {pos, store} <- store(instrs, idx, store_operand, arity),
        key_reg = Instr.register(key),
        match?({kind, _} when kind in [:x, :y], key_reg),
        do: %{at: idx, answer: answer, key: key_reg, pos: pos, store: store, absent: absent}
  end

  # A field of a parameter, or a named table.
  defp store(instrs, idx, operand, arity) do
    fields =
      for pos <- 0..(arity - 1)//1,
          key <- StateGate.field_read(instrs, idx, operand, pos),
          do: {pos, StateGate.spell_key(key)}

    case {fields, Resolve.resolve_register(instrs, idx, Instr.register(operand))} do
      {[], {:ok, table}} when is_atom(table) and table not in [nil, true, false, :dynamic] ->
        [{-1, "table " <> inspect(table)}]

      {fields, _} ->
        fields
    end
  end

  # The sites the absent walk reaches and the present walk misses, with
  # the argument of each that is the ask's key.
  defp gated(ask, instrs, tuple, labels, entry, sites) do
    tests = answer_tests(instrs, ask)

    if tests == %{} do
      []
    else
      absent = walk([entry], tuple, labels, tests, absent_answer(ask.absent), %{})
      present = walk([entry], tuple, labels, tests, present(ask.absent), %{})
      key = MapSet.new(Resolve.writers(instrs, ask.at, ask.key))

      for site <- sites,
          site != ask.at,
          Map.has_key?(absent, site),
          not Map.has_key?(present, site),
          arg <- key_args(instrs, site, key),
          do: {site, ask.pos, ask.store, arg}
    end
  end

  # The tests of the ask's answer, by index.
  defp answer_tests(instrs, ask) do
    for {instr, idx} <- Enum.with_index(instrs),
        idx > ask.at,
        operand <- tested(instr),
        answer_of?(instrs, idx, operand, ask),
        into: %{},
        do: {idx, instr}
  end

  defp tested({:test, _op, _fail, [operand | _]}), do: [operand]
  defp tested({:select_val, operand, _fail, _pairs}), do: [operand]
  defp tested(_instr), do: []

  defp answer_of?(instrs, idx, operand, ask) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        answer_origins(instrs, idx, reg) == [{ask.at, ask.answer}]

      _ ->
        false
    end
  end

  # Where the value in `reg` was written, copies followed.
  defp answer_origins(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, [], fn
      {:param, _k}, _follow -> []
      {at, instr}, _follow -> [{at, written_reg(instr, reg)}]
    end)
  end

  defp written_reg(instr, reg) do
    case Instr.defs(instr) do
      [one] -> one
      _ -> reg
    end
  end

  # Which of the site's arguments the key is: the same writes reach both.
  defp key_args(instrs, site, key) do
    instr = Reaching.at(instrs, site)

    instr
    |> arguments()
    |> Enum.with_index()
    |> Enum.filter(fn {reg, _i} ->
      not MapSet.disjoint?(key, MapSet.new(Resolve.writers(instrs, site, reg)))
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp arguments(:send), do: [{:x, 0}, {:x, 1}]

  defp arguments(instr), do: instr |> Instr.uses() |> Enum.filter(&match?({:x, _}, &1))

  defp site?(:send), do: true
  defp site?(instr), do: Instr.call?(instr) or Instr.tail_call?(instr)

  defp remote({op, _arity, {:extfunc, m, f, a}}) when op in [:call_ext, :call_ext_only],
    do: {:ok, {m, f, a}}

  defp remote({:call_ext_last, _arity, {:extfunc, m, f, a}, _dealloc}), do: {:ok, {m, f, a}}
  defp remote(_instr), do: :none

  defp absent_answer({:missing, atom}), do: {:atom, atom}
  defp absent_answer(absent), do: absent

  # The answer when the key is present: `true` for a membership (whose
  # absent answer is `false`), a non-empty list for an ETS lookup,
  # anything but the missing value for another lookup.
  defp present({:atom, false}), do: {:atom, true}
  defp present(:empty_list), do: :nonempty_list
  defp present({:missing, atom}), do: {:not, {:atom, atom}}
  defp present(absent), do: {:not, absent}

  # ── Walks ────────────────────────────────────────────────────────────
  #
  # The indices reached from the entry, the answer fixed at `value`: the
  # absent value, or `:present` (another value: `true` for a membership,
  # a found entry for a lookup). A test of the answer takes only the edges
  # the value can take; every other instruction takes each. `seen` is a
  # map, not a MapSet: dialyzer loses the MapSet's opacity through the
  # recursion.
  defp walk([], _tuple, _labels, _tests, _value, seen), do: seen

  defp walk([idx | rest], tuple, labels, tests, value, seen) do
    if idx >= tuple_size(tuple) or Map.has_key?(seen, idx) do
      walk(rest, tuple, labels, tests, value, seen)
    else
      instr = elem(tuple, idx)

      next =
        case Map.fetch(tests, idx) do
          {:ok, test} -> decide(test, idx, value, labels) || step(instr, idx, labels)
          :error -> step(instr, idx, labels)
        end

      walk(next ++ rest, tuple, labels, tests, value, Map.put(seen, idx, true))
    end
  end

  defp step(instr, idx, labels) do
    fall = if Instr.falls_through?(instr), do: [idx + 1], else: []
    fall ++ Enum.flat_map(Instr.targets(instr), &goto(&1, labels))
  end

  defp goto(label, labels) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> [idx]
      :error -> []
    end
  end

  # The edges a test takes for the value, or nil for both.
  defp decide({:test, op, {:f, fail}, [_a, b]}, idx, value, labels) when op in @eq_ops do
    case equal(b, value) do
      :unknown ->
        nil

      equal? ->
        passes? = if op in [:is_eq_exact, :is_eq], do: equal?, else: not equal?
        if passes?, do: [idx + 1], else: goto(fail, labels)
    end
  end

  defp decide({:select_val, _src, {:f, fail}, {:list, pairs}}, _idx, value, labels) do
    answers =
      for [literal, {:f, label}] <- Enum.chunk_every(pairs, 2), do: {equal(literal, value), label}

    taken =
      for {answer, label} <- answers, answer != false, target <- goto(label, labels), do: target

    default = if Enum.any?(answers, &(elem(&1, 0) == true)), do: [], else: goto(fail, labels)
    taken ++ default
  end

  defp decide({:test, op, {:f, fail}, _operands}, idx, value, labels) do
    case type_test(op, value) do
      :unknown -> nil
      true -> [idx + 1]
      false -> goto(fail, labels)
    end
  end

  defp decide(_instr, _idx, _value, _labels), do: nil

  # A type test of the answer for the value.
  @non_atom_types [:is_tuple, :is_tagged_tuple, :test_arity, :is_list, :is_nil, :is_nonempty_list] ++
                    [
                      :is_map,
                      :is_integer,
                      :is_binary,
                      :is_pid,
                      :is_reference,
                      :is_float,
                      :is_number
                    ]

  defp type_test(:is_atom, {:atom, _a}), do: true
  defp type_test(op, {:atom, _a}) when op in @non_atom_types, do: false
  defp type_test(op, :empty_list) when op in [:is_list, :is_nil], do: true

  defp type_test(op, :empty_list)
       when op in [:is_nonempty_list, :is_tuple, :is_tagged_tuple, :test_arity, :is_atom, :is_map],
       do: false

  defp type_test(op, :nonempty_list) when op in [:is_list, :is_nonempty_list], do: true

  defp type_test(op, :nonempty_list)
       when op in [:is_nil, :is_tuple, :is_tagged_tuple, :test_arity, :is_atom, :is_map],
       do: false

  defp type_test(_op, _value), do: :unknown

  # Whether a literal operand equals the value: `true`, `false`, or
  # `:unknown`. `nil` is the empty list.
  defp equal(literal, {:not, excluded}) do
    if equal(literal, excluded) == true, do: false, else: :unknown
  end

  defp equal({:atom, a}, {:atom, b}), do: a == b
  defp equal({:literal, a}, {:atom, b}) when is_atom(a), do: a == b
  defp equal(nil, {:atom, _b}), do: false
  defp equal({kind, _}, {:atom, _b}) when kind in [:integer, :float], do: false
  defp equal(nil, :empty_list), do: true
  defp equal({:literal, []}, :empty_list), do: true
  defp equal({:atom, _a}, :empty_list), do: false
  defp equal(nil, :nonempty_list), do: false
  defp equal({:literal, []}, :nonempty_list), do: false
  defp equal({:atom, _a}, :nonempty_list), do: false
  defp equal(_literal, _value), do: :unknown
end
