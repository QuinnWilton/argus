defmodule Argus.Extractors.StateGate do
  @moduledoc """
  Where a server's handler runs only while a field of its state says it
  has not yet, and what the server's returns set that field to.

  `def handle_info(:registered, %{registered: false} = state)` arms its
  loop and returns `%{state | registered: true}`: the arm runs only while
  the field holds `false`, and the clause's own return sets it to `true`.
  When no return of the server's callbacks sets it back, the arm runs at
  most once per incarnation of the process (clientlib/runs.dl's
  `gated_once_site`, docs/design/runs.md).

  Read in the callbacks of a GenServer's loop: handle_call/3,
  handle_cast/2, handle_info/2 and handle_continue/2, whose last argument
  is the state and whose result hands the next one back (`{:noreply,
  state, ...}`, `{:reply, reply, state, ...}`; a `{:stop, ...}` ends the
  process), and code_change/3 (`{:ok, state}`) for what a return sets.
  Whether the module is a GenServer is the rules' to ask.

  A field is read where the test reads the state the callback was handed:
  a map pattern (`%{registered: false} = state`), a map field
  (`state.owner`, fast path and slow path alike, `:erlang.map_get/2` in a
  guard), or a record field (`#state{overall = undefined}`, `element/2`
  in a guard). A field read off a value made from the state (a nested
  map, `Map.get/2`, a helper's answer) is not one.

  ## Emitted facts

  - `state_gate(site, func, key, value)` — the call (or send) at `site`
    runs only while the state holds the atom `value` under `key`: on
    every path from func's entry to the site, the tests of that field
    admit only the values of its rows (`if state.owner` admits `nil` and
    `false`). Walked once per value the function compares the field with,
    and once for a value it compares with none (a field that is absent
    among them): the site is gated when that last walk misses it.
  - `gate_closed(site, func, key)` — every way func completes after the
    site hands back a state whose `key` holds a value no state_gate row of
    the site admits: a literal outside them, a value no atom is (a
    reference, a pid, a number, a tuple — what a call known to answer one
    made, the caller in handle_call/3's `from`), or no such field, or the
    completion ends the process (a `{:stop, ...}`, a raise). A return
    through a local helper handed the state reads the helper's returns; a
    `throw` after the site (gen_server takes the thrown value as the
    callback's result), a return the reading cannot follow, or one that
    hands the state back unchanged, closes nothing. The handler of a
    `try` the site may be inside is a way to complete.
  - `state_excluded(site, func, key, value)` — the call (or send) at
    `site` does not run while the state holds the atom `value` under
    `key`: the walk for that value misses it, and another walk reaches it.
    `handle_info(ev, %{status: :init} = s)` queues the event and the
    next clause serves it: the serving call is excluded while the status
    is `:init`, whatever else admits it.
  - `state_return(func, clause, key, value)` — a way the callback
    completes, in the clause of its first argument's tag `clause` (`*`
    where no tag is established on the way), hands back a state whose
    `key` holds `value`: a literal (inspected), `nonatom` (a value no atom
    is) or `dynamic` (anything, the state included when the return cannot
    be read). Read for the keys some state_gate or state_excluded row of
    the module names, in the four handlers, code_change/3, and init/1,
    whose `{:ok, state, ...}` is the state each incarnation starts with.
    A return that keeps the field, or ends the process, has no row.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Dispatch
  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  import Argus.Extractor.Facts, only: [add_fact: 3]

  # The handlers whose state a gate reads, by the argument that holds it.
  @gated %{
    {:handle_call, 3} => 2,
    {:handle_cast, 2} => 1,
    {:handle_info, 2} => 1,
    {:handle_continue, 2} => 1
  }

  # The callbacks whose returns set the state: the handlers, and
  # code_change/3's `{:ok, state}`; init/1's `{:ok, state}` starts it, and
  # holds no state to keep (-1 names no parameter).
  @setting @gated |> Map.put({:code_change, 3}, 1) |> Map.put({:init, 1}, -1)

  @eq_ops [:is_eq_exact, :is_ne_exact, :is_eq, :is_ne]

  # What a call that never returns ends: the process, for a callback.
  # `throw` is not one: gen_server takes a thrown value as the result,
  # and neither is `erlang:raise/3` of a class it does not spell `error`
  # or `exit` (`throw` among them).
  @raising [
    {:erlang, :error, 1},
    {:erlang, :error, 2},
    {:erlang, :error, 3},
    {:erlang, :exit, 1},
    {:erlang, :nif_error, 1},
    {:erlang, :nif_error, 2}
  ]

  # Calls that answer a value no atom is: a reference, a pid, a number,
  # a tuple. What a gate's field is set to from one of these is outside
  # any atom the gate admits.
  @nonatom_calls MapSet.new(
                   [
                     {:erlang, :make_ref, 0},
                     {:erlang, :monitor, 2},
                     {:erlang, :monitor, 3},
                     {:erlang, :send_after, 3},
                     {:erlang, :send_after, 4},
                     {:erlang, :start_timer, 3},
                     {:erlang, :start_timer, 4},
                     {:erlang, :self, 0},
                     {:erlang, :open_port, 2},
                     {:erlang, :system_time, 0},
                     {:erlang, :system_time, 1},
                     {:erlang, :monotonic_time, 0},
                     {:erlang, :monotonic_time, 1},
                     {:erlang, :unique_integer, 0},
                     {:erlang, :unique_integer, 1},
                     {:erlang, :timestamp, 0},
                     {Process, :monitor, 1},
                     {Process, :monitor, 2},
                     {Process, :send_after, 3},
                     {Process, :send_after, 4},
                     {System, :monotonic_time, 0},
                     {System, :monotonic_time, 1},
                     {System, :system_time, 0},
                     {System, :system_time, 1},
                     {System, :os_time, 0},
                     {System, :os_time, 1},
                     {System, :unique_integer, 0},
                     {System, :unique_integer, 1},
                     {:os, :timestamp, 0},
                     {:os, :system_time, 0},
                     {:os, :system_time, 1}
                   ] ++
                     for(
                       f <- [:spawn, :spawn_link, :spawn_monitor, :spawn_opt],
                       a <- 1..5,
                       do: {:erlang, f, a}
                     )
                 )

  # Guard BIFs that answer a number.
  @number_bifs [
    :+,
    :-,
    :*,
    :/,
    :div,
    :rem,
    :band,
    :bor,
    :bxor,
    :bsl,
    :bsr,
    :bnot,
    :abs,
    :length,
    :size,
    :tuple_size,
    :map_size,
    :byte_size,
    :bit_size,
    :float,
    :round,
    :trunc,
    :ceil,
    :floor
  ]

  @impl true
  def relations, do: [:state_gate, :gate_closed, :state_excluded, :state_return]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{module: mod, functions: functions}) do
    bodies =
      Map.new(functions, fn {:function, name, arity, _entry, instrs} ->
        {{name, arity}, instrs}
      end)

    ctx = %{mod: mod, bodies: bodies}

    walked =
      for {fa, pos} <- Enum.sort(@gated),
          instrs = Map.get(bodies, fa),
          instrs != nil,
          walks <- field_walks(instrs, pos),
          do: Map.merge(walks, %{fa: fa, pos: pos, instrs: instrs})

    gates = for walks <- walked, gate <- gates(walks), do: Map.merge(walks, gate)
    exclusions = for walks <- walked, excluded <- exclusions(walks), do: {walks.fa, excluded}

    keys =
      (Enum.map(gates, & &1.key) ++ Enum.map(exclusions, &elem(&1, 1).key))
      |> Enum.uniq()
      |> Enum.sort()

    facts = Enum.reduce(gates, %{}, &emit_gate(ctx, &1, &2))
    facts = Enum.reduce(exclusions, facts, &emit_excluded(ctx, &1, &2))

    for {{name, arity} = fa, pos} <- Enum.sort(@setting),
        Map.has_key?(bodies, fa),
        key <- keys,
        {clause, value} <- clause_outs(fa, ctx, pos, key),
        reduce: facts do
      acc ->
        add_fact(acc, :state_return, [
          Normalize.func_id(mod, name, arity),
          clause,
          spell_key(key),
          value
        ])
    end
  end

  def extract(_module_data), do: %{}

  defp emit_gate(ctx, %{fa: {name, arity}} = gate, facts) do
    func_id = Normalize.func_id(ctx.mod, name, arity)
    site = InstrId.mint(func_id, gate.site)
    key = spell_key(gate.key)

    facts =
      Enum.reduce(gate.admitted, facts, fn value, acc ->
        add_fact(acc, :state_gate, [site, func_id, key, inspect(value)])
      end)

    if closed?(ctx, gate),
      do: add_fact(facts, :gate_closed, [site, func_id, key]),
      else: facts
  end

  defp emit_excluded(ctx, {{name, arity}, %{site: site, key: key, excluded: atoms}}, facts) do
    func_id = Normalize.func_id(ctx.mod, name, arity)
    id = InstrId.mint(func_id, site)

    Enum.reduce(atoms, facts, fn value, acc ->
      add_fact(acc, :state_excluded, [id, func_id, spell_key(key), inspect(value)])
    end)
  end

  # ── Gates ────────────────────────────────────────────────────────────
  #
  # Per field a callback tests of its state, the sites it reaches from its
  # entry once for each atom the function compares the field with, and
  # once for a value it compares with none.

  defp field_walks(instrs, pos) do
    tuple = List.to_tuple(instrs)
    labels = Dispatch.labels(instrs)
    entry = Dispatch.entry_index(instrs)

    tests =
      for {instr, idx} <- Enum.with_index(instrs),
          {key, test} <- field_test(instrs, idx, instr, pos),
          do: {key, idx, test}

    sites = for {instr, idx} <- Enum.with_index(instrs), site?(instr), do: idx

    tests
    |> Enum.group_by(&elem(&1, 0), fn {_key, idx, test} -> {idx, test} end)
    |> Enum.sort()
    |> Enum.map(fn {key, key_tests} ->
      key_tests = Map.merge(shape_tests(instrs, pos, key), Map.new(key_tests))
      atoms = key_tests |> Map.values() |> Enum.flat_map(&compared_atoms/1) |> Enum.uniq()
      other = reach(tuple, labels, [entry], &decide(key_tests, &1, &2, :other, labels))

      by_value =
        for atom <- atoms,
            do:
              {atom,
               reach(tuple, labels, [entry], &decide(key_tests, &1, &2, {:is, atom}, labels))}

      %{key: key, sites: sites, other: other, by_value: by_value}
    end)
  end

  # The sites the field lets run only for some of the atoms the function
  # compares it with: the walk for a value it compares with none misses
  # them.
  defp gates(%{key: key, sites: sites, other: other, by_value: by_value}) do
    for site <- sites,
        not Map.has_key?(other, site),
        admitted = for({atom, reached} <- by_value, Map.has_key?(reached, site), do: atom),
        admitted != [],
        do: %{site: site, key: key, admitted: Enum.sort(admitted)}
  end

  # The sites some walk reaches that the walk for an atom misses: they do
  # not run while the field holds it.
  defp exclusions(%{key: key, sites: sites, other: other, by_value: by_value}) do
    for site <- sites,
        reached?(site, other, by_value),
        excluded = for({atom, reached} <- by_value, not Map.has_key?(reached, site), do: atom),
        excluded != [],
        do: %{site: site, key: key, excluded: Enum.sort(excluded)}
  end

  defp reached?(site, other, by_value),
    do:
      Map.has_key?(other, site) or Enum.any?(by_value, fn {_atom, r} -> Map.has_key?(r, site) end)

  defp site?(:send), do: true
  defp site?(instr), do: Instr.call?(instr) or Instr.tail_call?(instr)

  # A test of the state's field: an equality with a literal, or a select
  # on it. What it compares the field with.
  defp field_test(instrs, idx, {:test, op, _fail, [a, b]}, pos) when op in @eq_ops do
    cond do
      literal?(b) -> for key <- field_read(instrs, idx, a, pos), do: {key, {:eq, b}}
      literal?(a) -> for key <- field_read(instrs, idx, b, pos), do: {key, {:eq, a}}
      true -> []
    end
  end

  defp field_test(instrs, idx, {:select_val, src, _fail, {:list, pairs}}, pos) do
    atoms =
      for {literal, i} <- Enum.with_index(pairs),
          rem(i, 2) == 0,
          atom <- atom_of(literal),
          do: atom

    for key <- field_read(instrs, idx, src, pos), do: {key, {:select, atoms}}
  end

  defp field_test(_instrs, _idx, _instr, _pos), do: []

  defp compared_atoms({:eq, literal}), do: atom_of(literal)
  defp compared_atoms({:select, atoms}), do: atoms
  defp compared_atoms(:shape), do: []

  # The tests of the state's shape a field is read under: a record's
  # (`#state{}`: is_tagged_tuple, is_tuple, test_arity) and a map's
  # (is_map, and a get_map_elements that reads the key). A walk that
  # fixes the field at an atom has a state that holds the field: those
  # tests pass. vernemq's tries serve `{update_subscriber, ...}` in a
  # clause that takes any state, after one for `#state{status = init}`:
  # the serving clause is reached past the record test only when the
  # state is no such record, which it always is.
  defp shape_tests(instrs, pos, key) do
    for {instr, idx} <- Enum.with_index(instrs),
        shape_test?(instrs, idx, instr, pos, key),
        into: %{},
        do: {idx, :shape}
  end

  defp shape_test?(instrs, idx, {:test, op, _fail, [operand | _]}, pos, {:record, _i})
       when op in [:is_tagged_tuple, :is_tuple, :test_arity],
       do: state?(instrs, idx, operand, pos)

  defp shape_test?(instrs, idx, {:test, :is_map, _fail, [operand]}, pos, {:map, _key}),
    do: state?(instrs, idx, operand, pos)

  defp shape_test?(
         instrs,
         idx,
         {:get_map_elements, _fail, src, {:list, pairs}},
         pos,
         {:map, key}
       ),
       do: {:atom, key} in Enum.take_every(pairs, 2) and state?(instrs, idx, src, pos)

  defp shape_test?(_instrs, _idx, _instr, _pos, _key), do: false

  defp atom_of({:atom, atom}), do: [atom]
  defp atom_of({:literal, atom}) when is_atom(atom), do: [atom]
  defp atom_of(_literal), do: []

  defp literal?({:atom, _}), do: true
  defp literal?({:integer, _}), do: true
  defp literal?({:float, _}), do: true
  defp literal?({:literal, _}), do: true
  defp literal?(nil), do: true
  defp literal?(_operand), do: false

  # The field of the state (parameter `pos` as the callback was handed
  # it) the operand holds on every path: `[key]`, or `[]` when some write
  # of it is anything else.
  defp field_read(instrs, idx, operand, pos) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        keys =
          instrs
          |> origins(idx, reg)
          |> Enum.map(fn
            {at, written} -> read_field(instrs, at, Reaching.at(instrs, at), written, pos)
            :param -> :no
          end)
          |> Enum.uniq()

        case keys do
          [{:ok, key}] -> [key]
          _ -> []
        end

      _ ->
        []
    end
  end

  # The writes that made the value in `reg` at `idx`, copies followed,
  # each with the register it wrote. A copy met again round a loop adds
  # nothing its first meeting did not.
  # `seen` and `visiting` below are maps, not MapSets: dialyzer loses the
  # MapSet's opacity through the recursion.
  defp origins(instrs, idx, reg), do: origins(instrs, idx, reg, %{})

  defp origins(instrs, idx, reg, seen) do
    if Map.has_key?(seen, {idx, reg}) do
      []
    else
      seen = Map.put(seen, {idx, reg}, true)

      instrs
      |> Reaching.sources(idx, reg)
      |> Enum.flat_map(fn
        {:param, _k} ->
          [:param]

        at ->
          case Instr.copy_source(Reaching.at(instrs, at), reg) do
            {kind, _} = source when kind in [:x, :y] -> origins(instrs, at, source, seen)
            _ -> [{at, reg}]
          end
      end)
    end
  end

  # A struct's `__struct__` is the state's type, not a status of it.
  defp read_field(instrs, at, {:get_map_elements, _fail, src, {:list, pairs}}, reg, pos) do
    with {:ok, {:atom, key}} when key != :__struct__ <- key_for(pairs, reg),
         true <- state?(instrs, at, src, pos) do
      {:ok, {:map, key}}
    else
      _ -> :no
    end
  end

  defp read_field(instrs, at, {:bif, :map_get, _fail, [{:atom, key}, src], _dst}, _reg, pos)
       when key != :__struct__ do
    if state?(instrs, at, src, pos), do: {:ok, {:map, key}}, else: :no
  end

  defp read_field(instrs, at, {:bif, :element, _fail, [{:integer, n}, src], _dst}, _reg, pos) do
    if state?(instrs, at, src, pos), do: {:ok, {:record, n - 1}}, else: :no
  end

  defp read_field(instrs, at, {:get_tuple_element, src, i, _dst}, _reg, pos) do
    cond do
      state?(instrs, at, src, pos) -> {:ok, {:record, i}}
      i == 1 -> slow_path(instrs, at, src, pos)
      true -> :no
    end
  end

  defp read_field(_instrs, _at, _instr, _reg, _pos), do: :no

  # Elixir's slow path for `state.key`: `{:ok, value}` from
  # `:elixir_erl_pass.no_parens_remote(state, :key)`, whose element 1 is
  # the value; it agrees with the fast path's map pattern at their join.
  defp slow_path(instrs, at, src, pos) do
    case origins(instrs, at, Instr.register(src)) do
      [{call, {:x, 0}}] ->
        with {:call_ext, 2, {:extfunc, :elixir_erl_pass, :no_parens_remote, 2}} <-
               Reaching.at(instrs, call),
             {:ok, key} when is_atom(key) and key not in [:dynamic, :__struct__] <-
               Resolve.resolve_register(instrs, call, {:x, 1}),
             true <- state?(instrs, call, {:x, 0}, pos) do
          {:ok, {:map, key}}
        else
          _ -> :no
        end

      _ ->
        :no
    end
  end

  # Whether the operand holds, on every path, the state as the callback
  # was handed it.
  defp state?(instrs, at, operand, pos) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> Resolve.writers(instrs, at, reg) == [{:param, pos}]
      _ -> false
    end
  end

  defp key_for([key, dst | rest], reg) do
    if Instr.register(dst) == reg, do: {:ok, key}, else: key_for(rest, reg)
  end

  defp key_for(_pairs, _reg), do: :none

  # ── Walks ────────────────────────────────────────────────────────────
  #
  # The instruction indices reached from `starts`, taking at each test of
  # the field only the edges the value can take: `{:is, atom}` a value
  # the function compares the field with, `:other` any value it does not
  # (another atom, a value of another type, an absent field). A test the
  # value does not decide, and every other instruction, takes each edge.

  defp reach(tuple, labels, starts, decide), do: walk(starts, tuple, labels, decide, %{})

  defp walk([], _tuple, _labels, _decide, seen), do: seen

  defp walk([idx | rest], tuple, labels, decide, seen) do
    if idx >= tuple_size(tuple) or Map.has_key?(seen, idx) do
      walk(rest, tuple, labels, decide, seen)
    else
      instr = elem(tuple, idx)
      next = decide.(idx, instr) || step(instr, idx, labels)
      walk(next ++ rest, tuple, labels, decide, Map.put(seen, idx, true))
    end
  end

  # A call that raises does not return: the compiler lays the next clause
  # after `erlang:error/3` (`if state.owner, do: raise ...`), and control
  # does not fall into it.
  defp step(instr, idx, labels) do
    fall = if Instr.falls_through?(instr) and not raises?(instr), do: [idx + 1], else: []
    fall ++ Enum.flat_map(Instr.targets(instr), &goto(&1, labels))
  end

  defp raises?(instr) do
    case callee(instr) do
      {:ok, mfa} -> mfa in @raising or mfa in [{:erlang, :throw, 1}, {:erlang, :raise, 3}]
      :none -> false
    end
  end

  defp goto(label, labels) do
    case Map.fetch(labels, label) do
      {:ok, idx} -> [idx]
      :error -> []
    end
  end

  defp free(_idx, _instr), do: nil

  defp decide(key_tests, idx, instr, value, labels) do
    case Map.fetch(key_tests, idx) do
      {:ok, {:eq, literal}} -> decide_eq(instr, idx, equal(literal, value), labels)
      {:ok, {:select, _atoms}} -> decide_select(instr, value, labels)
      {:ok, :shape} -> decide_shape(idx, value)
      :error -> nil
    end
  end

  # A state that holds the field has the shape the field is read under;
  # one of another value may hold no such field.
  defp decide_shape(idx, {:is, _atom}), do: [idx + 1]
  defp decide_shape(_idx, :other), do: nil

  defp decide_eq(_instr, _idx, :unknown, _labels), do: nil

  defp decide_eq({:test, op, {:f, fail}, _operands}, idx, equal?, labels) do
    passes? = if op in [:is_eq_exact, :is_eq], do: equal?, else: not equal?
    if passes?, do: [idx + 1], else: goto(fail, labels)
  end

  defp decide_select({:select_val, _src, {:f, fail}, {:list, pairs}}, value, labels) do
    arms = Enum.chunk_every(pairs, 2)
    answers = for [literal, {:f, label}] <- arms, do: {equal(literal, value), label}

    taken =
      for {answer, label} <- answers, answer != false, label <- goto(label, labels), do: label

    default = if Enum.any?(answers, &match?({true, _}, &1)), do: [], else: goto(fail, labels)
    taken ++ default
  end

  # Whether a literal equals the value: an atom by identity; an atom
  # never equals a literal of another type; `:other` equals no atom the
  # function compares the field with, and may equal any other literal.
  defp equal({:atom, a}, {:is, b}), do: a == b
  defp equal({:atom, _a}, :other), do: false
  defp equal({:literal, a}, {:is, b}) when is_atom(a), do: a == b
  defp equal({:literal, a}, :other) when is_atom(a), do: false
  defp equal(_literal, {:is, _atom}), do: false
  defp equal(_literal, :other), do: :unknown

  # ── What the state is after the site ────────────────────────────────

  defp closed?(ctx, %{instrs: instrs, site: site, pos: pos, key: key, admitted: admitted}) do
    tuple = List.to_tuple(instrs)
    labels = Dispatch.labels(instrs)
    starts = [site | handlers_around(instrs, tuple, labels, site)]
    reached = reach(tuple, labels, starts, &free/2)

    if Enum.any?(Map.keys(reached), &throws?(instrs, &1, elem(tuple, &1))) do
      false
    else
      reached
      |> Map.keys()
      |> Enum.filter(&completes?(elem(tuple, &1)))
      |> Enum.flat_map(&completion_outs(ctx, instrs, &1, pos, key, :tuple, %{}))
      |> Enum.all?(&outside?(&1, admitted))
    end
  end

  # The handlers of every `try` or `catch` from which the site can be
  # reached: the site may be in what it protects, and an exception there
  # goes on at the handler.
  defp handlers_around(instrs, tuple, labels, site) do
    for {instr, idx} <- Enum.with_index(instrs),
        handler <- handler_label(instr),
        Map.has_key?(reach(tuple, labels, [idx], &free/2), site),
        target <- goto(handler, labels),
        do: target
  end

  defp handler_label({:try, _reg, {:f, label}}), do: [label]
  defp handler_label({:catch, _reg, {:f, label}}), do: [label]
  defp handler_label(_instr), do: []

  # A throw, or a raise of a class that may be `throw`: gen_server takes
  # what it carries as the handler's result.
  defp throws?(instrs, idx, instr) do
    case callee(instr) do
      {:ok, {:erlang, :throw, 1}} -> true
      {:ok, {:erlang, :raise, 3}} -> not crash_class?(instrs, idx)
      _ -> false
    end
  end

  defp crash_class?(instrs, idx),
    do: Resolve.resolve_register(instrs, idx, {:x, 0}) in [{:ok, :error}, {:ok, :exit}]

  defp completes?(:return), do: true
  defp completes?(instr), do: Instr.tail_call?(instr)

  defp outside?(:stop, _admitted), do: true
  defp outside?(:nonatom, _admitted), do: true
  defp outside?({:set, value}, admitted), do: not (is_atom(value) and value in admitted)
  defp outside?(_out, _admitted), do: false

  # What each way the callback completes hands back under `key`, by the
  # clause of its first argument's tag the completion is in ("*" where no
  # tag is established on the way, Dispatch.argument_tags/2): spelled
  # {clause, value} pairs, a way that keeps the field or ends the process
  # left out.
  defp clause_outs(fa, ctx, pos, key) do
    instrs = Map.fetch!(ctx.bodies, fa)
    tuple = List.to_tuple(instrs)
    labels = Dispatch.labels(instrs)
    reached = reach(tuple, labels, [Dispatch.entry_index(instrs)], &free/2)
    tags = Dispatch.argument_tags(instrs, {:x, 0})

    outs =
      if Enum.any?(Map.keys(reached), &throws?(instrs, &1, elem(tuple, &1))) do
        [{["*"], :dynamic}]
      else
        for idx <- Map.keys(reached),
            completes?(elem(tuple, idx)),
            out <-
              completion_outs(ctx, instrs, idx, pos, key, :tuple, %{{fa, pos, :tuple} => true}),
            do: {clauses(tags, idx), out}
      end

    for {clauses, out} <- outs, clause <- clauses, value <- spell_out(out), uniq: true do
      {clause, value}
    end
  end

  defp clauses(tags, idx) do
    tags
    |> Map.get(idx, MapSet.new([:any]))
    |> Enum.map(fn
      :any -> "*"
      tag -> tag
    end)
  end

  # Every way the function completes, from its entry, read at `level`:
  # `:tuple` for a callback's result, `:value` for a helper that returns
  # the state itself.

  defp outs(ctx, fa, pos, key, level, visiting) do
    instrs = Map.get(ctx.bodies, fa)

    cond do
      instrs == nil ->
        [:dynamic]

      Map.has_key?(visiting, {fa, pos, level}) ->
        # A way round a recursion hands back what its other ways do.
        []

      true ->
        visiting = Map.put(visiting, {fa, pos, level}, true)
        tuple = List.to_tuple(instrs)
        labels = Dispatch.labels(instrs)
        reached = reach(tuple, labels, [Dispatch.entry_index(instrs)], &free/2)

        if Enum.any?(Map.keys(reached), &throws?(instrs, &1, elem(tuple, &1))) do
          [:dynamic]
        else
          reached
          |> Map.keys()
          |> Enum.filter(&completes?(elem(tuple, &1)))
          |> Enum.flat_map(&completion_outs(ctx, instrs, &1, pos, key, level, visiting))
          |> Enum.uniq()
        end
    end
  end

  # What a completion hands back under `key`: `:keep` (the state as it
  # came), `{:set, literal}`, `:nonatom`, `:dynamic`; `:stop` for the
  # process's end (a `{:stop, ...}`, a raise).
  defp completion_outs(ctx, instrs, idx, pos, key, level, visiting) do
    case Reaching.at(instrs, idx) do
      :return when level == :tuple -> result_outs(ctx, instrs, idx, {:x, 0}, pos, key, visiting)
      :return -> state_outs(ctx, instrs, idx, {:x, 0}, pos, key, visiting)
      instr -> tail_outs(ctx, instrs, idx, instr, pos, key, level, visiting)
    end
  end

  defp tail_outs(ctx, instrs, idx, instr, pos, key, level, visiting) do
    case callee(instr) do
      {:ok, {m, f, a}} when m == ctx.mod ->
        helper_outs(ctx, instrs, idx, {f, a}, pos, key, level, visiting)

      {:ok, mfa} when mfa in @raising ->
        [:stop]

      {:ok, {:erlang, :raise, 3}} ->
        if crash_class?(instrs, idx), do: [:stop], else: [:dynamic]

      _ ->
        [:dynamic]
    end
  end

  # A local helper handed the state: what its own completions hand back,
  # the state as it came being the argument it holds it in.
  defp helper_outs(ctx, instrs, idx, {_f, a} = fa, pos, key, level, visiting) do
    case for(j <- 0..(a - 1)//1, state?(instrs, idx, {:x, j}, pos), do: j) do
      [] -> [:dynamic]
      js -> Enum.flat_map(js, &outs(ctx, fa, &1, key, level, visiting))
    end
  end

  # A callback's result: the state it hands back, by the result's shape.
  defp result_outs(ctx, instrs, at, reg, pos, key, visiting) do
    instrs
    |> Resolve.writers(at, reg)
    |> Enum.flat_map(fn
      {:param, _k} ->
        [:dynamic]

      widx ->
        case Reaching.at(instrs, widx) do
          {:put_tuple2, _dst, {:list, [head | rest]}} ->
            slot_outs(ctx, instrs, widx, Instr.register(head), rest, pos, key, visiting)

          {:move, {:literal, result}, _dst} when is_tuple(result) and tuple_size(result) > 0 ->
            literal_result(result, key)

          instr ->
            case callee(instr) do
              {:ok, {m, f, a}} when m == ctx.mod and elem(instr, 0) == :call ->
                helper_outs(ctx, instrs, widx, {f, a}, pos, key, :tuple, visiting)

              _ ->
                [:dynamic]
            end
        end
    end)
  end

  defp slot_outs(_ctx, _instrs, _at, {:atom, :stop}, _rest, _pos, _key, _visiting), do: [:stop]
  defp slot_outs(_ctx, _instrs, _at, {:atom, :error}, _rest, _pos, _key, _visiting), do: [:keep]

  defp slot_outs(ctx, instrs, at, {:atom, head}, [state | _], pos, key, visiting)
       when head in [:noreply, :ok],
       do: state_outs(ctx, instrs, at, state, pos, key, visiting)

  defp slot_outs(ctx, instrs, at, {:atom, :reply}, [_reply, state | _], pos, key, visiting),
    do: state_outs(ctx, instrs, at, state, pos, key, visiting)

  defp slot_outs(_ctx, _instrs, _at, _head, _rest, _pos, _key, _visiting), do: [:dynamic]

  defp literal_result(result, key) do
    case Tuple.to_list(result) do
      [:stop | _] -> [:stop]
      [:error | _] -> [:keep]
      [head, state | _] when head in [:noreply, :ok] -> literal_state(state, key)
      [:reply, _reply, state | _] -> literal_state(state, key)
      _ -> [:dynamic]
    end
  end

  # The state a result holds: what its `key` is.
  defp state_outs(ctx, instrs, at, operand, pos, key, visiting) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        instrs
        |> Resolve.writers(at, reg)
        |> Enum.flat_map(fn
          {:param, ^pos} -> [:keep]
          {:param, _k} -> [:dynamic]
          widx -> written_state(ctx, instrs, widx, Reaching.at(instrs, widx), pos, key, visiting)
        end)

      literal ->
        case literal_term(literal) do
          {:ok, term} -> literal_state(term, key)
          :error -> [:dynamic]
        end
    end
  end

  defp written_state(ctx, instrs, at, {op, _fail, src, _dst, _live, {:list, pairs}}, pos, key, v)
       when op in [:put_map_assoc, :put_map_exact] do
    case {key, pair_value(pairs, key)} do
      {{:map, _}, {:ok, value}} -> value_of(ctx, instrs, at, value)
      {{:map, _}, :none} -> state_outs(ctx, instrs, at, src, pos, key, v)
      {{:record, _}, _} -> [:dynamic]
    end
  end

  defp written_state(
         ctx,
         instrs,
         at,
         {:update_record, _hint, _size, src, _dst, {:list, ups}},
         pos,
         key,
         v
       ) do
    case key do
      {:record, i} ->
        case record_update(ups, i + 1) do
          {:ok, value} -> value_of(ctx, instrs, at, value)
          :none -> state_outs(ctx, instrs, at, src, pos, key, v)
        end

      {:map, _} ->
        [:dynamic]
    end
  end

  defp written_state(ctx, instrs, at, {:put_tuple2, _dst, {:list, elements}}, _pos, key, _v) do
    case key do
      {:record, i} when i > 0 and i < length(elements) ->
        value_of(ctx, instrs, at, Enum.at(elements, i))

      _ ->
        [:dynamic]
    end
  end

  defp written_state(_ctx, _instrs, _at, {:move, {:literal, term}, _dst}, _pos, key, _v),
    do: literal_state(term, key)

  defp written_state(ctx, instrs, at, {:call, _arity, {m, f, a}}, pos, key, v) when m == ctx.mod,
    do: helper_outs(ctx, instrs, at, {f, a}, pos, key, :value, v)

  defp written_state(_ctx, _instrs, _at, _instr, _pos, _key, _v), do: [:dynamic]

  # The value a literal state holds under the key: a map's (absent is no
  # atom a gate admits), a record's element.
  defp literal_state(state, {:map, key}) when is_map(state) do
    case Map.fetch(state, key) do
      {:ok, value} when is_atom(value) -> [{:set, value}]
      {:ok, _value} -> [:nonatom]
      :error -> [:nonatom]
    end
  end

  defp literal_state(state, {:record, i})
       when is_tuple(state) and i > 0 and i < tuple_size(state) do
    case elem(state, i) do
      value when is_atom(value) -> [{:set, value}]
      _value -> [:nonatom]
    end
  end

  defp literal_state(_state, _key), do: [:dynamic]

  defp literal_term({:atom, a}), do: {:ok, a}
  defp literal_term({:integer, n}), do: {:ok, n}
  defp literal_term({:float, f}), do: {:ok, f}
  defp literal_term({:literal, term}), do: {:ok, term}
  defp literal_term(nil), do: {:ok, []}
  defp literal_term(_operand), do: :error

  defp pair_value([{:atom, k}, value | _rest], {:map, k}), do: {:ok, value}
  defp pair_value([_k, _v | rest], key), do: pair_value(rest, key)
  defp pair_value(_pairs, _key), do: :none

  # update_record's positions are 1-based.
  defp record_update([{:integer, p}, value | _rest], p), do: {:ok, value}
  defp record_update([p, value | _rest], p) when is_integer(p), do: {:ok, value}
  defp record_update([_p, _v | rest], p), do: record_update(rest, p)
  defp record_update(_updates, _p), do: :none

  # What a field is set to: a literal, or what made the register.
  defp value_of(ctx, instrs, at, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        instrs
        |> Resolve.writers(at, reg)
        |> Enum.map(fn
          {:param, _k} -> :dynamic
          widx -> made(ctx, instrs, widx, Reaching.at(instrs, widx))
        end)

      literal ->
        case literal_term(literal) do
          {:ok, term} when is_atom(term) -> [{:set, term}]
          {:ok, _term} -> [:nonatom]
          :error -> [:dynamic]
        end
    end
  end

  defp made(_ctx, _instrs, _at, {:move, {:atom, atom}, _dst}), do: {:set, atom}
  defp made(_ctx, _instrs, _at, {:move, {:literal, term}, _dst}), do: literal_made(term)
  defp made(_ctx, _instrs, _at, {:move, {:integer, _}, _dst}), do: :nonatom
  defp made(_ctx, _instrs, _at, {:move, nil, _dst}), do: :nonatom
  defp made(_ctx, _instrs, _at, {:bif, :self, _fail, [], _dst}), do: :nonatom

  defp made(_ctx, _instrs, _at, {:gc_bif, op, _fail, _live, _args, _dst}) when op in @number_bifs,
    do: :nonatom

  defp made(_ctx, _instrs, _at, {:put_tuple2, _dst, _elements}), do: :nonatom
  defp made(_ctx, _instrs, _at, {:put_list, _head, _tail, _dst}), do: :nonatom

  defp made(_ctx, _instrs, _at, {op, _, _, _, _, _}) when op in [:put_map_assoc, :put_map_exact],
    do: :nonatom

  defp made(_ctx, _instrs, _at, {:make_fun3, _, _, _, _, _}), do: :nonatom
  defp made(_ctx, _instrs, _at, {:bs_create_bin, _, _, _, _, _, _}), do: :nonatom

  # The caller's pid in handle_call/3's `from`, `{pid, tag}`.
  defp made(_ctx, instrs, at, {:get_tuple_element, src, 0, _dst}) do
    if handle_call?(instrs) and state?(instrs, at, src, 1), do: :nonatom, else: :dynamic
  end

  defp made(_ctx, _instrs, _at, instr) do
    case callee(instr) do
      {:ok, mfa} -> if MapSet.member?(@nonatom_calls, mfa), do: :nonatom, else: :dynamic
      :none -> :dynamic
    end
  end

  defp literal_made(term) when is_atom(term), do: {:set, term}
  defp literal_made(_term), do: :nonatom

  defp handle_call?(instrs),
    do: Enum.any?(instrs, &match?({:func_info, _, {:atom, :handle_call}, 3}, &1))

  defp callee({op, _arity, {:extfunc, m, f, a}}) when op in [:call_ext, :call_ext_only],
    do: {:ok, {m, f, a}}

  defp callee({:call_ext_last, _arity, {:extfunc, m, f, a}, _dealloc}), do: {:ok, {m, f, a}}
  defp callee({op, _arity, {m, f, a}}) when op in [:call, :call_only], do: {:ok, {m, f, a}}
  defp callee({:call_last, _arity, {m, f, a}, _dealloc}), do: {:ok, {m, f, a}}
  defp callee(_instr), do: :none

  # ── Spelling ─────────────────────────────────────────────────────────

  defp spell_key({:map, key}), do: inspect(key)
  defp spell_key({:record, i}), do: "{#{i}}"

  defp spell_out({:set, value}) when is_atom(value), do: [inspect(value)]
  defp spell_out({:set, _value}), do: ["nonatom"]
  defp spell_out(:nonatom), do: ["nonatom"]
  defp spell_out(:dynamic), do: ["dynamic"]
  defp spell_out(:keep), do: []
  defp spell_out(:stop), do: []
end
