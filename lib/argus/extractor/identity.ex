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
  @type origins :: {%{{String.t(), non_neg_integer(), String.t()} => [term()]}, String.t()}

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

  defp local_identity(instrs, idx, register, {index, func_id} = origins, depth) do
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
  nothing about its elements, and is `{"dynamic", ""}`.
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
