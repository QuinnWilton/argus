defmodule Argus.Extractor.StateFields do
  @moduledoc """
  What a function's returns set in the state they hand back, field by
  field, and what each field's value is made of.

  ## The fields

  `returned_fields/2` reads the fields a `return` sets: of the map it
  returns itself, or of one an element of the returned tuple holds — a
  callback's `{:noreply, [], %{state | receive_timer: nil}}` — and of an
  Erlang record the same way (`State#state{subs = Subs}`, a field spelled
  as its 0-based tuple position, `{2}`, as PidFlow spells one). A state
  built whole in a callback's state slot (the record or map after `ok` in
  `{ok, State}`, a literal or built there) sets every field it has. A
  state in that slot that is neither the one the callback was given nor
  one these fields spell (a `maps:put/3`'s result, a helper's) sets the
  whole state, key `*`. Each field comes with its value's spelling (a
  literal, inspected, or `dynamic`) and, when the value is built at run
  time, where: the instruction that builds the term and the operand it
  puts there.

  ## What a value is made of

  `made_of/3` is the backward closure of the writes a value is built
  from, on every path: the operands of a tuple, a list, a map (its base
  and its pairs), a record update; a call into another module, whose
  answer is made of its arguments as well as of the call (`Map.put(subs,
  pid, ref)` is made of `ref`). A BIF other than a projection holds none
  of its operands: `node(pid)` is no pid. A local call is a leaf:
  what it answers is the callee's, and the rules compose it through the
  callee's own returns (`returns_from`). The writes are named by their
  instruction indices, and the function's parameters by `{:param, k}`.

  A projection (`get_tuple_element`, a list's head or tail, a map's
  fields, `element/2`, `hd/1`, `map_get/2`) is a write of its own, and
  what it projects from is made `:part` of the value: a value made of one
  element of a message is not the message. `:whole` holds the writes the
  value is made of whole — itself, or held in a term it is — and `:part`
  those it holds a piece of. So a field that stores the pid a clause took
  out of its message is made whole of that projection, and only in part
  of the message; the closure of a field that stores another element of
  the message meets the message, not the pid. `:arg` holds the writes
  reached through another call's arguments: what `Map.put(subs, pid,
  ref)` was handed, which its answer holds, but also what
  `assign(socket, :cache, Map.delete(cache, k))` was: the value is that
  call's answer, not the removal's.

  The closure is bounded (fuel): a value built around a loop too long to
  follow is read as far as the fuel goes, which leaves out writes, never
  invents them.
  """

  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @typedoc "A write a value is made of: its instruction's index, or a parameter."
  @type origin :: non_neg_integer() | {:param, non_neg_integer()}

  @typedoc "What a value is made of: whole, and in part."
  @type made :: %{
          whole: MapSet.t(origin()),
          part: MapSet.t(origin()),
          arg: MapSet.t(origin()),
          pieces: MapSet.t({origin(), non_neg_integer()})
        }

  @typedoc """
  A field a return sets: its key, its value's spelling, and where the
  value is built (`{at, operand}`), or nil for a literal.
  """
  @type field :: {String.t(), String.t(), {non_neg_integer(), term()} | nil}

  @fuel 512

  # Projections: what they read is made part of what they write.
  @projections [:get_tuple_element, :get_hd, :get_tl, :get_map_elements]
  @projecting_bifs [:element, :hd, :tl, :map_get, :binary_part]

  @doc "The fields the `return` at `idx` sets (see the moduledoc)."
  @spec returned_fields([Instr.instr()], non_neg_integer()) :: [field()]
  def returned_fields(instrs, idx) do
    instrs
    |> Resolve.writers(idx, {:x, 0})
    |> Enum.flat_map(fn
      {:param, _k} ->
        []

      at ->
        case Reaching.at(instrs, at) do
          {:put_tuple2, _dst, {:list, [head | _] = elements}} ->
            size = length(elements)

            elements
            |> Enum.with_index()
            |> Enum.flat_map(fn {element, i} ->
              element_updates(instrs, at, element, state_slot?(head, size, i))
            end)

          {:move, {:literal, term}, _dst} when is_tuple(term) and tuple_size(term) > 0 ->
            head = {:atom, elem(term, 0)}

            term
            |> Tuple.to_list()
            |> Enum.with_index()
            |> Enum.flat_map(fn {element, i} ->
              literal_state(element, state_slot?(head, tuple_size(term), i))
            end)

          {:move, {:literal, term}, _dst} ->
            literal_state(term, false)

          instr ->
            state_updates(at, instr, false)
        end
    end)
  end

  # What an element of a returned tuple sets. In the state slot (`whole`)
  # a value that is the parameter the callback was given sets nothing, and
  # one whose fields cannot be read sets the whole state.
  defp element_updates(instrs, at, element, whole) do
    case Instr.register(element) do
      {kind, _} = reg when kind in [:x, :y] ->
        Enum.flat_map(Resolve.writers(instrs, at, reg), fn
          {:param, _k} -> []
          w -> written_state(w, Reaching.at(instrs, w), whole, {at, element})
        end)

      {:literal, term} ->
        literal_state(term, whole)

      _ ->
        []
    end
  end

  defp written_state(_w, {:move, {:literal, term}, _dst}, whole, _loc),
    do: literal_state(term, whole)

  defp written_state(w, instr, whole, loc) do
    case state_updates(w, instr, whole) do
      [] when whole -> [{"*", "dynamic", loc}]
      pairs -> pairs
    end
  end

  # Where a callback's return holds the state it hands back, built whole
  # there (a record the compiler makes afresh, `{noreply, {state, none}}`
  # when the record has one field), so a record in that slot is read field
  # by field: after `ok` or `noreply`, after the reply in `{reply, R, S}`,
  # the last of a `stop`, and a gen_statem's data. Elsewhere a tuple with
  # an atom first is as likely a `{continue, x}` as a record, and is not
  # read.
  defp state_slot?({:atom, tag}, _size, 1) when tag in [:ok, :noreply, :keep_state], do: true
  defp state_slot?({:atom, tag}, _size, 2) when tag in [:reply, :next_state], do: true
  defp state_slot?({:atom, :stop}, size, i) when size in [3, 4] and i == size - 1, do: true
  defp state_slot?(_head, _size, _i), do: false

  defp state_updates(at, {op, _fail, _src, _dst, _live, {:list, pairs}}, _whole)
       when op in [:put_map_assoc, :put_map_exact] do
    pairs
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [{:atom, key}, value] -> [{inspect(key), literal_value(value), location(at, value)}]
      _ -> []
    end)
  end

  # Positions are 1-based in the instruction, 0-based in the key.
  defp state_updates(at, {:update_record, _hint, _size, _src, _dst, {:list, updates}}, _whole) do
    updates
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      [{:integer, pos}, value] ->
        [{"{#{pos - 1}}", literal_value(value), location(at, value)}]

      [pos, value] when is_integer(pos) ->
        [{"{#{pos - 1}}", literal_value(value), location(at, value)}]

      _ ->
        []
    end)
  end

  defp state_updates(at, {:put_tuple2, _dst, {:list, [{:atom, _tag} | fields]}}, true) do
    fields
    |> Enum.with_index(1)
    |> Enum.map(fn {value, pos} -> {"{#{pos}}", literal_value(value), location(at, value)} end)
  end

  defp state_updates(_at, _instr, _whole), do: []

  defp location(at, value) do
    case Instr.register(value) do
      {kind, _} when kind in [:x, :y] -> {at, value}
      _ -> nil
    end
  end

  defp literal_state(map, _whole) when is_map(map) do
    map
    |> Map.to_list()
    |> Enum.filter(fn {key, _value} -> is_atom(key) end)
    |> Enum.map(fn {key, value} -> {inspect(key), Terms.spell(value), nil} end)
  end

  defp literal_state(tuple, true) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    if is_atom(elem(tuple, 0)) do
      tuple
      |> Tuple.to_list()
      |> tl()
      |> Enum.with_index(1)
      |> Enum.map(fn {value, pos} -> {"{#{pos}}", Terms.spell(value), nil} end)
    else
      [{"*", Terms.spell(tuple), nil}]
    end
  end

  # A whole state that is a literal of no fields (a counter's `0`, a
  # `nil`): the state it sets.
  defp literal_state(term, true), do: [{"*", Terms.spell(term), nil}]
  defp literal_state(_term, _whole), do: []

  defp literal_value(nil), do: "[]"
  defp literal_value({:atom, atom}), do: inspect(atom)
  defp literal_value({:integer, n}), do: Integer.to_string(n)
  defp literal_value({:literal, term}), do: Terms.spell(term)
  defp literal_value(_register), do: "dynamic"

  @doc """
  What the value `operand` holds at `at` (before the instruction there
  runs) is made of (see the moduledoc).
  """
  @spec made_of([Instr.instr()], non_neg_integer(), term()) :: made()
  def made_of(instrs, at, operand) do
    case register(operand) do
      nil -> empty()
      reg -> walk([{at, reg, :whole}], instrs, %{}, empty(), @fuel)
    end
  end

  # What a call's argument is made of, as what the call answers holds it.
  defp argument_of(instrs, at, operand) do
    case register(operand) do
      nil -> empty()
      reg -> walk([{at, reg, :arg}], instrs, %{}, empty(), @fuel)
    end
  end

  @doc """
  What the function hands back is made of: what each `return` holds in
  `x0`, and each tail call's answer — the call itself and, for a call
  into another module, its arguments. A tail call that raises is none.
  With `among`, only the ways out at those indices (`reachable_from/2`).
  """
  @spec returned_made_of([Instr.instr()], MapSet.t(non_neg_integer()) | :all) :: made()
  def returned_made_of(instrs, among \\ :all) do
    instrs
    |> Enum.with_index()
    |> Enum.filter(fn {_instr, idx} -> among == :all or MapSet.member?(among, idx) end)
    |> Enum.reduce(empty(), fn {instr, idx}, acc ->
      cond do
        instr == :return ->
          merge(acc, made_of(instrs, idx, {:x, 0}))

        Instr.tail_call?(instr) and not raising?(instr) ->
          acc = %{acc | whole: MapSet.put(acc.whole, idx)}

          if remote?(instr),
            do: Enum.reduce(Instr.uses(instr), acc, &merge(&2, argument_of(instrs, idx, &1))),
            else: acc

        true ->
          acc
      end
    end)
  end

  @doc """
  The instruction indices control may reach after the instruction at
  `idx` runs: by falling through and by every branch, exceptions left
  out. What a run that passed `idx` can go on to: the returns and calls
  of its own clause, not another clause's that shares a destructuring
  with it.
  """
  @spec reachable_from([Instr.instr()], non_neg_integer()) :: MapSet.t(non_neg_integer())
  def reachable_from(instrs, idx) do
    code = List.to_tuple(instrs)
    labels = for {{:label, l}, i} <- Enum.with_index(instrs), into: %{}, do: {l, i}
    code |> successors(labels, idx) |> reach(code, labels, %{}) |> Map.keys() |> MapSet.new()
  end

  # `seen` is a map, not a MapSet: dialyzer loses the MapSet's opacity
  # through the recursion.
  defp reach([], _code, _labels, seen), do: seen

  defp reach([i | rest], code, labels, seen) do
    if i >= tuple_size(code) or Map.has_key?(seen, i),
      do: reach(rest, code, labels, seen),
      else: reach(successors(code, labels, i) ++ rest, code, labels, Map.put(seen, i, true))
  end

  defp successors(code, labels, i) do
    instr = elem(code, i)
    fall = if Instr.falls_through?(instr), do: [i + 1], else: []
    fall ++ for(l <- Instr.targets(instr), at = Map.get(labels, l), at != nil, do: at)
  end

  @doc "Whether `made` is made of the write `origin`, whole or in part."
  @spec made_of?(made(), origin()) :: boolean()
  def made_of?(%{whole: whole, part: part, arg: arg}, origin),
    do:
      MapSet.member?(whole, origin) or MapSet.member?(part, origin) or MapSet.member?(arg, origin)

  @doc """
  The calls among `made`'s writes, with how the value holds each one's
  answer: `"whole"` (the answer, or a term that holds it), `"{i}"` (its
  element `i`, taken out by a `get_tuple_element`), `"part"` (another
  piece of it), or `"argument"` (only through another call's
  arguments).
  """
  @spec calls([Instr.instr()], made()) :: [{non_neg_integer(), String.t()}]
  def calls(instrs, %{whole: whole, part: part, arg: arg, pieces: pieces}) do
    whole_calls = Enum.filter(whole, &call_at?(instrs, &1))
    piece_calls = for {o, i} <- pieces, call_at?(instrs, o), do: {o, "{#{i}}"}
    pieced = MapSet.new(piece_calls, &elem(&1, 0))

    part_calls =
      for o <- part, call_at?(instrs, o), o not in whole_calls, o not in pieced, do: {o, "part"}

    valued = MapSet.new(whole_calls) |> MapSet.union(MapSet.new(part, & &1))
    arg_calls = for o <- arg, call_at?(instrs, o), o not in valued, do: {o, "argument"}

    Enum.sort(Enum.map(whole_calls, &{&1, "whole"}) ++ piece_calls ++ part_calls ++ arg_calls)
  end

  defp call_at?(instrs, origin), do: is_integer(origin) and call?(Reaching.at(instrs, origin))

  defp empty,
    do: %{whole: MapSet.new(), part: MapSet.new(), arg: MapSet.new(), pieces: MapSet.new()}

  defp merge(a, b),
    do: %{
      whole: MapSet.union(a.whole, b.whole),
      part: MapSet.union(a.part, b.part),
      arg: MapSet.union(a.arg, b.arg),
      pieces: MapSet.union(a.pieces, b.pieces)
    }

  defp walk([], _instrs, _seen, made, _fuel), do: made
  defp walk(_work, _instrs, _seen, made, fuel) when fuel <= 0, do: made

  defp walk([{at, reg, mode} = item | rest], instrs, seen, made, fuel) do
    if Map.has_key?(seen, item) do
      walk(rest, instrs, seen, made, fuel)
    else
      seen = Map.put(seen, item, true)

      {made, more} =
        instrs
        |> Resolve.writers(at, reg)
        |> Enum.reduce({made, []}, fn writer, {made, more} ->
          made = add(made, mode, writer)

          case writer do
            {:param, _k} -> {made, more}
            w -> {made, reads(Reaching.at(instrs, w), w, below(mode)) ++ more}
          end
        end)

      walk(more ++ rest, instrs, seen, made, fuel - 1)
    end
  end

  defp add(made, :whole, writer), do: %{made | whole: MapSet.put(made.whole, writer)}
  defp add(made, :part, writer), do: %{made | part: MapSet.put(made.part, writer)}
  defp add(made, :arg, writer), do: %{made | arg: MapSet.put(made.arg, writer)}

  defp add(made, {:piece, i}, writer),
    do: %{
      made
      | part: MapSet.put(made.part, writer),
        pieces: MapSet.put(made.pieces, {writer, i})
    }

  # What the write at `w` is made of, and how: a projection's source in
  # part (and, for a tuple's element taken out of a value held whole, the
  # piece: the source's writers are made of that element), a local call
  # nothing (its callee's returns say), what a call was
  # through another call's arguments as an argument (and past one, an
  # argument it stays), anything else its operands as it is.
  defp reads({:get_tuple_element, src, i, _dst}, w, :whole), do: [{w, register(src), {:piece, i}}]

  defp reads(instr, w, mode) do
    cond do
      projection?(instr) -> operands(instr, w, if(mode == :arg, do: :arg, else: :part))
      computing_bif?(instr) -> []
      match?({:call, _, _}, instr) -> []
      Instr.call?(instr) -> operands(instr, w, :arg)
      true -> operands(instr, w, mode)
    end
  end

  defp operands(instr, w, mode), do: for(reg <- Instr.uses(instr), do: {w, reg, mode})

  # A piece is one level: below the writer that made the piece's term,
  # what it is made of is a part of the value.
  defp below({:piece, _i}), do: :part
  defp below(mode), do: mode

  # A BIF other than a projection computes a scalar from its operands
  # (`node(pid)`, a size, a comparison, arithmetic) and holds none of them.
  defp computing_bif?({:bif, _name, _fail, _args, _dst}), do: true
  defp computing_bif?({:gc_bif, _name, _fail, _live, _args, _dst}), do: true
  defp computing_bif?(_instr), do: false

  defp projection?(instr) when is_tuple(instr) and elem(instr, 0) in @projections, do: true
  defp projection?({:bif, name, _fail, _args, _dst}) when name in @projecting_bifs, do: true

  defp projection?({:gc_bif, name, _fail, _live, _args, _dst}) when name in @projecting_bifs,
    do: true

  defp projection?(_instr), do: false

  defp call?({op, _, _}) when op in [:call, :call_ext, :call_only, :call_ext_only], do: true
  defp call?({op, _, _, _}) when op in [:call_last, :call_ext_last], do: true
  defp call?(_instr), do: false

  defp remote?({op, _, _}) when op in [:call_ext, :call_ext_only], do: true
  defp remote?({:call_ext_last, _, _, _}), do: true
  defp remote?(_instr), do: false

  # Calls that never return: a tail call to one raises instead.
  @raising [error: 1, error: 2, exit: 1, throw: 1, raise: 3, nif_error: 1]

  defp raising?({:call_ext_only, _arity, {:extfunc, :erlang, name, arity}}),
    do: {name, arity} in @raising

  defp raising?({:call_ext_last, _arity, {:extfunc, :erlang, name, arity}, _dealloc}),
    do: {name, arity} in @raising

  defp raising?(_instr), do: false

  defp register({:tr, reg, _type}), do: register(reg)
  defp register({kind, _n} = reg) when kind in [:x, :y], do: reg
  defp register(_operand), do: nil
end
