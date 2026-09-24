defmodule Argus.Extractor.Identity do
  @moduledoc """
  What names the value a register holds, in the vocabulary two sites can
  be joined on — a literal, a parameter, a map field, or the one
  instruction that made it (`key_identity/4`), and the same for an
  element of a tuple (`tuple_element_identity/5`). A lookup and a create
  that agree on it name the same thing.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractor.Terms
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId
  alias Argus.Pipeline.Normalize

  @doc """
  What identifies the value in `register` at `idx`, in the vocabulary two
  sites can be joined on: `{"literal", inspected}` for an atom, binary or
  integer; `{"param", "N"}` when it is still the function's parameter N;
  `{"field", key}` when it was read from a map under a literal key;
  `{"element N", "P"}` when it is element N (from 0) of parameter P; else
  `{"dynamic", ""}`. A lookup and a create that agree on source and key
  name the same thing — the identity-through-a-name idea the timer rules
  use, spelled once.

  Given `origins` (`{origins_index(module_data), func_id}`), a value that
  is none of those can still be `{"local", instr_id}`: the one
  instruction that made it, found through reaching definitions and
  followed back through copies (moves, swaps, trims). Two operands with the same origin hold
  the same value — `key = {name, type}` handed to a read and then to a
  write — although nothing says what it is. Several definitions reaching
  the read (a join) stay dynamic. The instruction ID names a site in one
  function, so a local identity never agrees with anything outside it.
  Two origins say more than where: `self()` is `{"self", ""}`, the
  calling process, however many calls of it there are; and a tuple built
  of values that each have an identity is `{"tuple", "{param 0, param
  1}"}`, its elements' identities in order, so `{mod, fun}` spelled out
  at a lookup and again at the write is the same key. Both name something
  only within one function.
  """
  @spec key_identity([term()], non_neg_integer(), Resolve.register(), origins() | nil) ::
          {String.t(), String.t()}
  def key_identity(instrs, idx, register, origins \\ nil) do
    case Resolve.resolve_register(instrs, idx, register) do
      {:ok, value}
      when (is_atom(value) and value != :dynamic) or is_binary(value) or is_integer(value) ->
        {"literal", Terms.spell(value)}

      _ ->
        case Resolve.arg_position(instrs, idx, register) do
          {:ok, pos} ->
            {"param", to_string(pos)}

          :no ->
            case Resolve.map_field_of(instrs, idx, register) do
              {:ok, key} ->
                {"field", key}

              :dynamic ->
                case param_element(instrs, idx, register) do
                  {:ok, identity} -> identity
                  :no -> local_identity(instrs, idx, register, origins)
                end
            end
        end
    end
  end

  # An element of a parameter: `elem(record, 1)`, compiled to
  # `get_tuple_element` when the compiler knows the parameter is a tuple
  # and to the `element/2` BIF (1-based) when it does not. Named
  # `{"element N", "P"}`, N counted from 0 as tuple_element_identity/5
  # counts: the caller's argument at P says what it is.
  defp param_element(instrs, idx, register) do
    Resolve.trace(instrs, idx, register, :no, fn
      {:param, _k}, _follow ->
        :no

      {at, {:get_tuple_element, src, n, _dst}}, _follow ->
        element_of_param(instrs, at, src, n)

      {at, {:bif, :element, _fail, [{:integer, n}, src], _dst}}, _follow when n >= 1 ->
        element_of_param(instrs, at, src, n - 1)

      {at, {:gc_bif, :element, _fail, _live, [{:integer, n}, src], _dst}}, _follow when n >= 1 ->
        element_of_param(instrs, at, src, n - 1)

      _writer, _follow ->
        :no
    end)
  end

  defp element_of_param(instrs, at, src, n) do
    case Resolve.arg_position(instrs, at, src) do
      {:ok, pos} -> {:ok, {"element #{n}", to_string(pos)}}
      :no -> :no
    end
  end

  @typedoc """
  The reaching definitions of one module keyed by the read, and the
  function being asked about: what `key_identity/4` needs to name a value
  by the instruction that made it.
  """
  @type origins ::
          {%{{String.t(), non_neg_integer(), String.t()} => [term()]}, String.t()}
          | {%{{String.t(), non_neg_integer(), String.t()} => [term()]}, String.t(), returns()}

  @typedoc """
  Which of a module's functions return a parameter's tuple with element
  n unchanged (`returned_elements/2`): `%{{func_id, n} => param}`. Given
  as the third element of `origins`, a local call's result is followed
  into the argument it passes there.
  """
  @type returns :: %{{String.t(), non_neg_integer()} => non_neg_integer()}

  @doc """
  The module's reaching definitions (`Argus.Extractor.Helpers.reaching/1`)
  indexed by the read, `{func_id, idx, reg}`: paired with a function ID,
  the `origins` that
  `key_identity/4` takes. The pipeline builds it once per module as
  `module_data.origins_index`; this builds it for bare disassembly, and
  is empty when the facts cannot be decoded, which leaves every identity
  as it was without one.
  """
  @spec origins_index(map()) :: %{{String.t(), non_neg_integer(), String.t()} => [term()]}
  def origins_index(%{origins_index: index}), do: index

  def origins_index(module_data) do
    case Helpers.reaching(module_data) do
      nil ->
        %{}

      reaching ->
        Enum.group_by(
          reaching,
          fn {_source, reg, %InstrId{module: m, func: f, arity: a, idx: idx}} ->
            {InstrId.func_id(m, f, a), idx, reg}
          end,
          fn {source, _reg, _use} -> source end
        )
    end
  end

  # Moves and swaps are followed to what they copy; a chain longer than
  # this is a loop in the definitions (a receive loop), and names nothing.
  @max_move_chain 32

  defp local_identity(instrs, idx, register, origins, depth \\ 0)
  defp local_identity(_instrs, _idx, _register, nil, _depth), do: {"dynamic", ""}

  defp local_identity(_instrs, _idx, _register, _origins, depth) when depth > @max_move_chain,
    do: {"dynamic", ""}

  defp local_identity(instrs, idx, register, origins, depth) do
    {index, func_id} = {elem(origins, 0), elem(origins, 1)}

    with {kind, n} when kind in [:x, :y] <- Instr.register(register),
         [%InstrId{idx: def_idx}] <- Map.get(index, {func_id, idx, "#{kind}#{n}"}) do
      instr = Reaching.at(instrs, def_idx)

      case Instr.copy_source(instr, {kind, n}) do
        {skind, _} = reg when skind in [:x, :y] ->
          local_identity(instrs, def_idx, reg, origins, depth + 1)

        nil ->
          made_by(instrs, def_idx, instr, origins) ||
            {"local", InstrId.mint(func_id, def_idx)}

        _literal ->
          {"dynamic", ""}
      end
    else
      _ -> {"dynamic", ""}
    end
  end

  # What the one instruction that made a value says about it, beyond
  # where it was made. `self()` is the calling process, whichever call of
  # it made the value: `{"self", ""}`. A tuple built of values that each
  # have an identity is those identities in order, so `{mod, fun}` spelled
  # out at a lookup and again at the write is one key, as it is when bound
  # to a variable once: `{"tuple", "{param 0, param 1}"}`. Both still name
  # something only within one function (a parameter, a local, the calling
  # process), and cross no call.
  defp made_by(_instrs, _idx, {:bif, :self, _fail, [], _dst}, _origins), do: {"self", ""}

  defp made_by(instrs, idx, {:put_tuple2, _dst, {:list, elements}}, origins)
       when elements != [] do
    identities = Enum.map(elements, &element_identity(instrs, idx, &1, origins))

    if Enum.any?(identities, &match?({"dynamic", _}, &1)) do
      nil
    else
      {"tuple", "{" <> Enum.map_join(identities, ", ", fn {s, v} -> "#{s} #{v}" end) <> "}"}
    end
  end

  defp made_by(_instrs, _idx, _instr, _origins), do: nil

  @dynamic_identity {"dynamic", ""}

  @doc """
  `key_identity/4` for element `n` of the tuple in `register` at `idx`: an
  ETS object's key, a Mnesia record's table and key. The tuple is built by
  `put_tuple2` on the way to `idx` (through copies), or is one literal;
  when the arms of a `case` each build it, their identities must agree. A
  tuple that is still parameter P names its element as `{"element N",
  "P"}` — a record handed to a helper, whose caller's argument says what
  the element is. A tuple from anywhere else — a call result — says
  nothing about its elements, and is `{"dynamic", ""}` — except that a
  record updated in place (`put_elem/3`, `R#r{f = V}`, an Elixir record's
  update) keeps every element the update does not set, and the head of
  what `:mnesia.dirty_read` or `:ets.lookup` returned holds the table and
  key the read was asked for: `[rec] = dirty_read(t, k)` and then
  `dirty_write(put_elem(rec, 2, n + 1))` writes the record it read.
  """
  @spec tuple_element_identity(
          [term()],
          non_neg_integer(),
          Resolve.register(),
          non_neg_integer(),
          origins() | nil
        ) :: {String.t(), String.t()}
  def tuple_element_identity(instrs, idx, register, n, origins \\ nil) do
    Resolve.trace(instrs, idx, register, @dynamic_identity, fn
      {:param, k}, _follow ->
        {"element #{n}", to_string(k)}

      {at, {:put_tuple2, _dst, {:list, elements}}}, _follow when length(elements) > n ->
        element_identity(instrs, at, Enum.at(elements, n), origins)

      # A literal tuple moved into the register: the compiler folded it.
      {_at, {:move, {:literal, tuple}, _dst}}, _follow
      when is_tuple(tuple) and tuple_size(tuple) > n ->
        {"literal", Terms.spell(elem(tuple, n))}

      # A record updated in place, `R#r{f = V}` or an Elixir record's
      # update: element n is the original's unless the update sets it.
      {at, {:update_record, _hint, _size, src, _dst, {:list, updates}}}, follow ->
        if (n + 1) in updated_positions(updates), do: @dynamic_identity, else: follow.(at, src)

      # A local helper that hands back its parameter's tuple with element n
      # unchanged (a pipeline of `put_elem`s): the argument's element n.
      {at, {call, _arity, {mod, fun, arity}}}, follow when call in [:call, :call_only] ->
        case Map.fetch(returns_of(origins), {Normalize.func_id(mod, fun, arity), n}) do
          {:ok, pos} -> follow.(at, {:x, pos})
          :error -> @dynamic_identity
        end

      # The head of a list a read returned: the row or record it found.
      {at, {:get_list, src, _hd, _tl}}, _follow ->
        row_element(instrs, at, src, n, origins)

      {at, {:get_hd, src, _dst}}, _follow ->
        row_element(instrs, at, src, n, origins)

      {at, instr}, follow ->
        case Helpers.match_remote_call(instr) do
          {:ok, :erlang, :setelement, 3} -> setelement_element(instrs, at, n, follow)
          _ -> @dynamic_identity
        end

      _writer, _follow ->
        @dynamic_identity
    end)
  end

  # `put_elem(t, i, v)`, called at `at`: element n is t's unless i is n.
  defp setelement_element(instrs, at, n, follow) do
    case Resolve.resolve_register(instrs, at, {:x, 0}) do
      {:ok, i} when is_integer(i) and i != n + 1 -> follow.(at, {:x, 1})
      _ -> @dynamic_identity
    end
  end

  defp returns_of({_index, _func_id, returns}), do: returns
  defp returns_of(_origins), do: %{}

  @doc """
  The module's functions that return a parameter's tuple with element 0
  or 1 unchanged: every exit returns element n of the same parameter,
  through updates that set other elements (`record |> put_elem(3, ...)
  |> put_elem(4, ...)`). A Mnesia record's table and key, an ETS row's
  key. `%{{func_id, n} => param}`, the third element of `origins`.
  """
  @spec returned_elements(map(), %{{String.t(), non_neg_integer(), String.t()} => [term()]}) ::
          returns()
  def returned_elements(module_data, index) do
    for {:function, name, arity, _entry, instrs} <- module_data.functions,
        func_id = Normalize.func_id(module_data.module, name, arity),
        n <- [0, 1],
        {:ok, pos} <- [returned_element(instrs, n, {index, func_id})],
        into: %{},
        do: {{func_id, n}, pos}
  end

  defp returned_element(instrs, n, origins) do
    exits =
      for {instr, idx} <- Enum.with_index(instrs),
          identity = exit_element(instrs, idx, instr, n, origins),
          identity != :none,
          do: identity

    want = "element #{n}"

    case Enum.uniq(exits) do
      [{^want, pos}] -> {:ok, String.to_integer(pos)}
      _ -> :error
    end
  end

  defp exit_element(instrs, idx, :return, n, origins),
    do: tuple_element_identity(instrs, idx, {:x, 0}, n, origins)

  defp exit_element(instrs, idx, instr, n, origins) do
    tail? = match?({:call_ext_only, _, _}, instr) or match?({:call_ext_last, _, _, _}, instr)

    case {tail?, Helpers.match_remote_call(instr)} do
      {true, {:ok, :erlang, :setelement, 3}} ->
        setelement_element(instrs, idx, n, fn at, reg ->
          tuple_element_identity(instrs, at, reg, n, origins)
        end)

      {true, _other} ->
        @dynamic_identity

      {false, _} ->
        if tail_call?(instr), do: @dynamic_identity, else: :none
    end
  end

  defp tail_call?(instr) do
    match?({:call_only, _, _}, instr) or match?({:call_last, _, _, _}, instr) or
      match?({:apply_last, _, _}, instr) or match?({:call_fun2, _, _, _}, instr)
  end

  defp updated_positions(updates) do
    updates
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [{:integer, i} | _] -> i
      [i | _] -> i
    end)
  end

  # Element n of a row or record a read found, in the read's own terms:
  # a Mnesia record's table and key are what `dirty_read` was asked for
  # (`dirty_read(t, k)`, or the `{t, k}` it was handed); an ETS row's key
  # is what `lookup` was asked for. Its other elements are the store's,
  # and name nothing.
  defp row_element(instrs, at, list, n, origins) do
    Resolve.trace(instrs, at, list, @dynamic_identity, fn
      {call_at, instr}, _follow ->
        case {Helpers.match_remote_call(instr), n} do
          {{:ok, :mnesia, :dirty_read, 2}, n} when n in [0, 1] ->
            key_identity(instrs, call_at, {:x, n}, origins)

          {{:ok, :mnesia, :dirty_read, 1}, n} when n in [0, 1] ->
            tuple_element_identity(instrs, call_at, {:x, 0}, n, origins)

          {{:ok, :ets, :lookup, 2}, 0} ->
            key_identity(instrs, call_at, {:x, 1}, origins)

          _ ->
            @dynamic_identity
        end

      _writer, _follow ->
        @dynamic_identity
    end)
  end

  defp element_identity(_instrs, _idx, {:atom, atom}, _origins), do: {"literal", inspect(atom)}
  defp element_identity(_instrs, _idx, {:integer, n}, _origins), do: {"literal", inspect(n)}

  defp element_identity(_instrs, _idx, {:literal, value}, _origins),
    do: {"literal", Terms.spell(value)}

  defp element_identity(instrs, idx, operand, origins) do
    case Instr.register(operand) do
      {kind, _n} = reg when kind in [:x, :y] -> key_identity(instrs, idx, reg, origins)
      _other -> {"dynamic", ""}
    end
  end
end
