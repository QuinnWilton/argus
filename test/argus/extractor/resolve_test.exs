defmodule Argus.Extractor.ResolveTest do
  @moduledoc """
  `Argus.Extractor.Resolve.resolve_register/3` over generated straight-line
  code: what it answers for every register is what running the code
  leaves there, by an interpreter written beside it here. The code moves,
  swaps, builds lists, tuples and maps, takes them apart, runs the pure
  BIFs the resolver evaluates and ones it does not, calls (which write
  x0 and destroy the other x registers), and ends clauses (after which
  nothing written before reaches). A value is `{:ok, term}` or
  `:dynamic`; a part of a term nothing resolved is the `:dynamic`
  placeholder, as the resolver documents.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Extractor.{Resolve, Terms}

  @regs [x: 0, x: 1, x: 2, y: 0, y: 1]
  @pure [
    element: 2,
    tuple_size: 1,
    map_size: 1,
    byte_size: 1,
    length: 1,
    hd: 1,
    tl: 1,
    atom_to_binary: 1,
    ++: 2
  ]

  defp reg, do: member_of(@regs)

  # A register, maybe wrapped in a type as newer OTPs write it.
  defp reg_operand do
    bind(reg(), fn r -> one_of([constant(r), constant({:tr, r, {:t_atom, :any}})]) end)
  end

  defp leaf do
    one_of([
      map(member_of([:a, :b, :ok, :error, nil, true]), &{:atom, &1}),
      map(integer(), &{:integer, &1}),
      map(member_of([[1, 2], [:x], {:ok, 1}, %{k: 1}, "bin"]), &{:literal, &1})
    ])
  end

  # Mostly registers, so that one instruction reads what another wrote.
  defp operand, do: frequency([{3, reg_operand()}, {1, leaf()}, {1, constant(nil)}])

  defp instr do
    one_of([
      map(tuple({one_of([leaf(), reg_operand()]), reg_operand()}), fn {s, d} -> {:move, s, d} end),
      map(tuple({reg(), reg()}), fn {a, b} -> {:swap, a, b} end),
      map(tuple({operand(), operand(), reg_operand()}), fn {h, t, d} -> {:put_list, h, t, d} end),
      map(tuple({reg_operand(), list_of(operand(), min_length: 1, max_length: 3)}), fn {d, es} ->
        {:put_tuple2, d, {:list, es}}
      end),
      map(reg_operand(), &{:bif, :self, :nofail, [], &1}),
      map(tuple({reg_operand(), reg_operand()}), fn {s, d} -> {:get_hd, s, d} end),
      map(tuple({reg_operand(), reg_operand()}), fn {s, d} -> {:get_tl, s, d} end),
      map(tuple({reg_operand(), integer(0..2), reg_operand()}), fn {s, i, d} ->
        {:get_tuple_element, s, i, d}
      end),
      constant({:call, 1, {:f, 99}}),
      bind(member_of(@pure), fn {name, arity} ->
        map(tuple({list_of(operand(), length: arity), reg_operand()}), fn {args, d} ->
          {:gc_bif, name, {:f, 0}, 2, args, d}
        end)
      end),
      map(
        tuple(
          {member_of([:put_map_assoc, :put_map_exact]),
           one_of([constant({:literal, %{}}), constant({:literal, %{a: 1}}), reg_operand()]),
           reg_operand(), list_of(tuple({leaf(), operand()}), max_length: 2)}
        ),
        fn {op, src, d, pairs} ->
          {op, {:f, 0}, src, d, 1, {:list, Enum.flat_map(pairs, &Tuple.to_list/1)}}
        end
      ),
      map(
        tuple({reg_operand(), list_of(tuple({leaf(), reg()}), min_length: 1, max_length: 2)}),
        fn {s, pairs} ->
          {:get_map_elements, {:f, 0}, s, {:list, Enum.flat_map(pairs, &Tuple.to_list/1)}}
        end
      ),
      member_of([
        :return,
        {:call_only, 1, {:f, 20}},
        {:call_ext_only, 1, {:extfunc, :erlang, :error, 1}},
        {:call_last, 1, {:f, 30}, 2},
        {:call_ext_last, 1, {:extfunc, :erlang, :error, 1}, 2}
      ])
      |> map(&{:barrier, &1})
    ])
  end

  # --- the interpreter: each register's {:ok, term} or :dynamic, a term
  # holding the :dynamic placeholder where a part of it is unknown ---

  defp plain({:tr, r, _}), do: r
  defp plain(r), do: r

  defp operand(nil, _regs), do: {:ok, []}
  defp operand({:atom, a}, _), do: {:ok, a}
  defp operand({:integer, i}, _), do: {:ok, i}
  defp operand({:literal, t}, _), do: {:ok, t}
  defp operand(r, regs), do: Map.get(regs, plain(r), :dynamic)

  defp element(op, regs) do
    case operand(op, regs) do
      {:ok, v} -> v
      :dynamic -> :dynamic
    end
  end

  defp run({:move, s, d}, regs), do: Map.put(regs, plain(d), operand(s, regs))

  defp run({:swap, a, b}, regs),
    do: regs |> Map.put(a, operand(b, regs)) |> Map.put(b, operand(a, regs))

  # A cons onto a tail it cannot see ends in the placeholder; one onto a
  # known tail that is no list is no list a consumer can use.
  defp run({:put_list, h, t, d}, regs) do
    v =
      case operand(t, regs) do
        {:ok, list} when is_list(list) -> {:ok, [element(h, regs) | list]}
        :dynamic -> {:ok, [element(h, regs), :dynamic]}
        {:ok, _not_a_list} -> :dynamic
      end

    Map.put(regs, plain(d), v)
  end

  defp run({:put_tuple2, d, {:list, es}}, regs),
    do: Map.put(regs, plain(d), {:ok, es |> Enum.map(&element(&1, regs)) |> List.to_tuple()})

  defp run({:bif, _, _, _, d}, regs), do: Map.put(regs, plain(d), :dynamic)

  defp run({:get_hd, s, d}, regs) do
    v =
      case operand(s, regs) do
        {:ok, [h | _]} -> {:ok, h}
        _ -> :dynamic
      end

    Map.put(regs, plain(d), v)
  end

  defp run({:get_tl, s, d}, regs) do
    v =
      case operand(s, regs) do
        {:ok, [_ | t]} -> {:ok, t}
        _ -> :dynamic
      end

    Map.put(regs, plain(d), v)
  end

  defp run({:get_tuple_element, s, i, d}, regs) do
    v =
      case operand(s, regs) do
        {:ok, t} when is_tuple(t) and i < tuple_size(t) -> {:ok, elem(t, i)}
        _ -> :dynamic
      end

    Map.put(regs, plain(d), v)
  end

  defp run({:gc_bif, name, _, _, args, d}, regs),
    do: Map.put(regs, plain(d), bif(name, Enum.map(args, &element(&1, regs))))

  # What each BIF gives arguments it is defined on; anything else, the
  # resolver does not compute.
  defp bif(:element, [i, t]) when is_integer(i) and is_tuple(t) and i > 0 and i <= tuple_size(t),
    do: {:ok, elem(t, i - 1)}

  defp bif(:tuple_size, [t]) when is_tuple(t), do: {:ok, tuple_size(t)}
  defp bif(:map_size, [m]) when is_map(m), do: {:ok, map_size(m)}
  defp bif(:byte_size, [b]) when is_binary(b), do: {:ok, byte_size(b)}

  # A list holding the placeholder may end in a tail nothing resolved.
  defp bif(:length, [l]) when is_list(l) do
    if Terms.proper_list?(l) and :dynamic not in l, do: {:ok, length(l)}, else: :dynamic
  end

  defp bif(:hd, [[h | _]]), do: {:ok, h}
  defp bif(:tl, [[_ | t]]), do: {:ok, t}
  defp bif(:atom_to_binary, [a]) when is_atom(a) and not is_nil(a), do: {:ok, Atom.to_string(a)}

  defp bif(:++, [a, b]) when is_list(a) and is_list(b),
    do: if(Terms.proper_list?(a), do: {:ok, a ++ b}, else: :dynamic)

  defp bif(_name, _args), do: :dynamic

  defp run({op, _, src, d, _, {:list, pairs}}, regs)
       when op in [:put_map_assoc, :put_map_exact] do
    base =
      case src do
        {:literal, m} ->
          m

        r ->
          case element(r, regs) do
            m when is_map(m) -> m
            _ -> %{}
          end
      end

    pairs =
      pairs
      |> Enum.chunk_every(2)
      |> Map.new(fn [k, v] -> {element(k, regs), element(v, regs)} end)

    Map.put(regs, plain(d), {:ok, Map.merge(base, pairs)})
  end

  defp run({:get_map_elements, _, s, {:list, pairs}}, regs) do
    map = operand(s, regs)

    pairs
    |> Enum.chunk_every(2)
    |> Enum.reduce(regs, fn [k, d], acc ->
      v =
        case map do
          {:ok, m} when is_map(m) ->
            case Map.get(m, element(k, regs)) do
              nil -> :dynamic
              x -> {:ok, x}
            end

          _ ->
            :dynamic
        end

      # A destination named twice keeps the first pair's key.
      if Map.has_key?(acc, {:written, d}),
        do: acc,
        else: acc |> Map.put(d, v) |> Map.put({:written, d}, true)
    end)
    |> Map.reject(fn {k, _} -> match?({:written, _}, k) end)
  end

  # Past the end of a clause nothing written before it reaches.
  defp run({:barrier, _}, _regs), do: %{}

  # A call writes x0 and destroys the other x registers.
  defp run({:call, _, _}, regs),
    do: regs |> Enum.reject(fn {{k, _}, _} -> k == :x end) |> Map.new()

  # What a consumer is handed: the placeholder alone, or a list no list
  # operation accepts, is unresolved.
  defp expected({:ok, :dynamic}), do: :dynamic

  defp expected({:ok, list}) when is_list(list),
    do: if(Terms.proper_list?(list), do: {:ok, list}, else: :dynamic)

  defp expected(other), do: other

  property "a register resolves to what a straight-line run of the code leaves in it" do
    check all(instrs <- list_of(instr(), max_length: 8), max_runs: 10_000) do
      regs = Enum.reduce(instrs, %{}, &run/2)

      code =
        instrs
        |> Enum.with_index(100)
        |> Enum.flat_map(fn
          {{:barrier, b}, label} -> [b, {:label, label}]
          {instr, _} -> [instr]
        end)
        |> Kernel.++([{:call_ext, 1, {:extfunc, :erlang, :length, 1}}])

      at = length(code) - 1

      for r <- @regs do
        got = Resolve.resolve_register(code, at, r)
        want = expected(Map.get(regs, r, :dynamic))

        assert got == want,
               "#{inspect(r)}: resolver #{inspect(got)}, run #{inspect(want)}, after #{inspect(instrs, pretty: true)}"
      end
    end
  end
end
