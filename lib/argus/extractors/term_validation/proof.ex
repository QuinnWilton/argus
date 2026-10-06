defmodule Argus.Extractors.TermValidation.Proof do
  @moduledoc false

  alias Argus.Extractor.Helpers
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @safe_types [:atom, :number, :integer, :float, :binary, :bitstring, :pid, :reference, nil]
  @max_paths 512

  @spec proves?(map(), term(), MapSet.t()) :: boolean()
  def proves?(%{cfg: nil}, _, _), do: false

  def proves?(fun, role, contracts) do
    state = %{
      regs: Map.new(0..(fun.arity - 1)//1, &{{:x, &1}, {:param, &1}}),
      types: %{},
      safe: MapSet.new(),
      equal: %{},
      valid: true
    }

    state = initial(state, role)
    paths([{fun.cfg.entry, state, MapSet.new()}], fun, role, contracts, 0)
  end

  defp initial(st, :list), do: put_type(st, {:param, 0}, :list)
  defp initial(st, :map), do: put_type(st, {:param, 0}, :map)
  defp initial(st, :tuple_prefix), do: put_type(st, {:param, 0}, :tuple)
  defp initial(st, :map_entry), do: equate(st, {:param, 2}, {:literal, :ok})
  defp initial(st, _), do: st

  defp paths([], _, _, _, _), do: true
  defp paths(_, _, _, _, count) when count > @max_paths, do: false

  defp paths([{id, st, visited} | rest], fun, role, contracts, count) do
    if MapSet.member?(visited, id) do
      false
    else
      block = Map.fetch!(fun.cfg.blocks, id)
      {first, last} = block.range
      before = Enum.reduce(first..(last - 1)//1, st, &step(fun.instrs, &1, &2, contracts, role))
      instr = Reaching.at(fun.instrs, last)
      after_step = step(fun.instrs, last, before, contracts, role)

      cond do
        not after_step.valid ->
          false

        nonreturning?(instr) and block.succs == [] ->
          paths(rest, fun, role, contracts, count + 1)

        instr == :return or Instr.tail_call?(instr) ->
          returns?(after_step, role) and paths(rest, fun, role, contracts, count + 1)

        true ->
          next =
            for {dest, edge} <- block.succs,
                state = edge_state(instr, last, edge, before, after_step, role),
                state != nil,
                do: {dest, state, MapSet.put(visited, id)}

          paths(next ++ rest, fun, role, contracts, count + 1)
      end
    end
  end

  defp nonreturning?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, :erlang, fun, arity}
      when (fun in [:throw, :exit] and arity == 1) or (fun == :error and arity in [1, 2, 3]) ->
        true

      _ ->
        match?({:bif, :raise, _, _, _}, instr)
    end
  end

  defp returns?(%{regs: %{{:x, 0} => {:error_result, _}}}, {:decoder, _}), do: true

  defp returns?(st, {:decoder, at}) do
    match?({:error_result, _}, value(st, {:x, 0})) or
      not contains?(value(st, {:x, 0}), {:decoded, at}) or safe?(st, {:decoded, at})
  end

  defp returns?(st, role) do
    returned = value(st, {:x, 0})

    case accept(st, returned) do
      {:ok, accepted} -> goal?(accepted, role)
      :error -> role != :map_entry
      :unknown -> false
    end
  end

  defp accept(st, {:literal, :ok}), do: {:ok, st}
  defp accept(_st, {:tuple, [{:literal, :error} | _]}), do: :error
  defp accept(_st, {:literal, {:error, _}}), do: :error
  defp accept(_st, :error_result), do: :error
  defp accept(_st, {:error_result, _}), do: :error
  defp accept(st, {:verdict, _at, obligations}), do: {:ok, ensure(st, obligations)}
  defp accept(_st, _), do: :unknown

  defp goal?(st, :tuple_prefix), do: prefix?(st, {:param, 0}, {:param, 1})
  defp goal?(st, :map_entry), do: safe?(st, {:param, 0}) and safe?(st, {:param, 1})
  defp goal?(st, _), do: safe?(st, {:param, 0})

  defp value(st, operand) do
    raw =
      case Instr.register(operand) do
        {kind, _} = reg when kind in [:x, :y] -> Map.get(st.regs, reg, {:unknown, reg})
        {kind, literal} when kind in [:atom, :literal, :integer, :float] -> {:literal, literal}
        nil -> {:literal, []}
        _ -> :unknown
      end

    resolve(st, raw)
  end

  defp resolve(st, v), do: Map.get(st.equal, v, v)

  defp step(_instrs, _at, %{valid: false} = st, _contracts, _role), do: st

  defp step(instrs, at, st, contracts, role) do
    instr = Reaching.at(instrs, at)
    kept = Map.reject(st.regs, fn {reg, _} -> Instr.clobbers?(instr, reg) end)

    cond do
      Instr.call?(instr) or Instr.tail_call?(instr) ->
        call(instr, at, st, kept, contracts, role)

      match?({:trim, _, _}, instr) ->
        trim(st, instr)

      true ->
        regs =
          Enum.reduce(Instr.defs(instr), kept, fn reg, acc ->
            made =
              case Instr.copy_source(instr, reg) do
                nil -> made(instr, reg, st)
                source -> value(st, source)
              end

            Map.put(acc, reg, if(made == :unknown, do: {:unknown, at, reg}, else: made))
          end)

        %{st | regs: regs, valid: supported?(instr, st, role)}
    end
  end

  defp supported?(instr, st, {:decoder, at}) do
    Instr.known?(instr) and
      (structural?(instr) or
         Enum.all?(Instr.uses(instr), fn reg ->
           not contains?(value(st, reg), {:decoded, at}) or safe?(st, {:decoded, at})
         end))
  end

  defp supported?(instr, _st, _role), do: Instr.known?(instr) and validator_instruction?(instr)

  defp validator_instruction?({:bif, name, _, _, _}) when name in [:element, :tuple_size, :raise],
    do: true

  defp validator_instruction?({:gc_bif, :-, _, _, _, _}), do: true
  defp validator_instruction?({:make_fun3, _, _, _, _, {:list, []}}), do: true

  defp validator_instruction?(instr)
       when is_tuple(instr) and
              elem(instr, 0) in [:get_list, :get_hd, :get_tl, :get_tuple_element, :trim],
       do: true

  defp validator_instruction?(instr), do: structural?(instr)

  defp structural?(:return), do: true
  defp structural?({:test, _, _, _}), do: true

  defp structural?(instr) when is_tuple(instr),
    do:
      elem(instr, 0) in [
        :move,
        :put_tuple2,
        :put_list,
        :line,
        :debug_line,
        :executable_line,
        :label,
        :allocate,
        :allocate_heap,
        :test_heap,
        :deallocate,
        :try,
        :try_end,
        :try_case,
        :jump,
        :init_yregs,
        :func_info
      ]

  defp structural?(_), do: false

  defp made({:put_tuple2, _, {:list, args}}, _, st), do: {:tuple, Enum.map(args, &value(st, &1))}
  defp made({:put_list, head, tail, _}, _, st), do: {:cons, value(st, head), value(st, tail)}

  defp made({:get_list, src, head, _}, reg, st),
    do: {:field, value(st, src), if(Instr.register(head) == reg, do: :head, else: :tail)}

  defp made({:get_hd, src, _}, _, st), do: {:field, value(st, src), :head}
  defp made({:get_tl, src, _}, _, st), do: {:field, value(st, src), :tail}

  defp made({:get_tuple_element, src, n, _}, _, st),
    do: {:element, value(st, src), {:literal, n + 1}}

  defp made({:bif, name, _, args, _}, _, st), do: bif(name, Enum.map(args, &value(st, &1)))
  defp made({:gc_bif, name, _, _, args, _}, _, st), do: bif(name, Enum.map(args, &value(st, &1)))
  defp made({:make_fun3, mfa, _, _, _, {:list, []}}, _, _), do: {:closure, mfa}
  defp made(_, _, _), do: :unknown

  defp bif(:tuple_size, [tuple]), do: {:size, tuple}
  defp bif(:element, [index, tuple]), do: {:element, tuple, index}
  defp bif(:-, [index, {:literal, 1}]), do: {:previous, index}
  defp bif(_, _), do: :unknown

  defp trim(st, {:trim, removed, _}) do
    regs =
      for {reg, val} <- st.regs,
          match?({:x, _}, reg) or elem(reg, 1) >= removed,
          into: %{},
          do: {if(elem(reg, 0) == :y, do: {:y, elem(reg, 1) - removed}, else: reg), val}

    %{st | regs: regs}
  end

  defp call(instr, at, st, kept, contracts, role) do
    mfa =
      case Helpers.match_remote_call(instr) do
        {:ok, m, f, a} ->
          {m, f, a}

        _ ->
          case Helpers.match_local_call(instr) do
            {:ok, m, f, a} -> {m, f, a}
            _ -> nil
          end
      end

    args =
      if mfa,
        do: Enum.map(0..(elem(mfa, 2) - 1)//1, &value(st, {:x, &1})),
        else: Enum.map(Instr.uses(instr), &value(st, &1))

    result = result(mfa, args, at, st, contracts, role)
    result = if result == :unknown, do: {:unknown_call, at}, else: result
    allowed = allowed_call?(mfa, args, result, st, role)
    %{st | regs: Map.put(kept, {:x, 0}, result), valid: st.valid and allowed}
  end

  defp result({:erlang, :binary_to_term, 2}, _, at, _, _, {:decoder, at}), do: {:decoded, at}

  defp result({:maps, :fold, 3}, [{:closure, cb}, {:literal, :ok}, map], at, _, contracts, _) do
    if MapSet.member?(contracts, {cb, :map_entry}),
      do: {:verdict, at, [{:safe, map}]},
      else: :unknown
  end

  defp result(mfa, [term], at, st, contracts, _) do
    if Enum.any?([:term, :list, :map], fn role ->
         MapSet.member?(contracts, {mfa, role}) and (role == :term or type(st, term) == role)
       end), do: {:verdict, at, [{:safe, term}]}, else: :unknown
  end

  defp result(mfa, [tuple, count], at, st, contracts, _) do
    if MapSet.member?(contracts, {mfa, :tuple_prefix}) and type(st, tuple) == :tuple and
         count_for?(count, tuple), do: {:verdict, at, [{:prefix, tuple, count}]}, else: :unknown
  end

  defp result(_, _, _, _, _, _), do: :unknown

  defp count_for?({:size, tuple}, tuple), do: true
  defp count_for?({:previous, {:param, 1}}, {:param, 0}), do: true
  defp count_for?(_, _), do: false

  defp allowed_call?(_mfa, args, result, st, {:decoder, at}) do
    match?({:verdict, _, _}, result) or
      Enum.all?(args, &(not contains?(&1, {:decoded, at}) or safe?(st, {:decoded, at})))
  end

  defp allowed_call?(mfa, args, result, _st, _role) do
    match?({:verdict, _, _}, result) or
      (mfa in [{:erlang, :throw, 1}, {:erlang, :error, 1}, {:erlang, :exit, 1}] and
         Enum.all?(args, &error_argument?/1))
  end

  defp error_argument?(:error_result), do: true
  defp error_argument?({:error_result, _}), do: true
  defp error_argument?({:literal, _}), do: true
  defp error_argument?(_), do: false

  defp edge_state(_instr, at, :exception, before, _after, role) do
    kept = Map.reject(before.regs, fn {{kind, _}, _} -> kind == :x end)
    regs = Enum.reduce(0..2, kept, &Map.put(&2, {:x, &1}, {:exception, at, &1}))
    %{before | regs: regs, valid: before.valid and safe_exception?(before, role)}
  end

  defp edge_state({:test, op, _, args}, _at, edge, before, after_st, _role)
       when edge in [:branch_pass, :branch_fail],
       do: test(op, Enum.map(args, &value(before, &1)), edge == :branch_pass, after_st)

  defp edge_state(_, _, _, _, after_st, _role), do: after_st

  defp safe_exception?(st, {:decoder, at}) do
    safe?(st, {:decoded, at}) or
      not Enum.any?(st.regs, fn {_, value} -> contains?(value, {:decoded, at}) end)
  end

  defp safe_exception?(_, _), do: true

  defp test(op, [a, b], pass, st) when op in [:is_eq_exact, :is_ne_exact] do
    equal = if op == :is_eq_exact, do: pass, else: not pass
    equality(a, b, equal, st)
  end

  defp test(:is_tagged_tuple, [term, _size, {:literal, :error}], true, st),
    do: equate(st, term, :error_result)

  defp test(:is_nonempty_list, [term], false, st) do
    if type(st, term) == :list, do: put_type(st, term, nil), else: st
  end

  defp test(op, [term], pass, st), do: guard(term, tested_type(op), pass, st)

  defp test(_, _, _, st), do: st

  defp tested_type(:is_atom), do: :atom
  defp tested_type(:is_number), do: :number
  defp tested_type(:is_integer), do: :integer
  defp tested_type(:is_float), do: :float
  defp tested_type(:is_binary), do: :binary
  defp tested_type(:is_bitstr), do: :bitstring
  defp tested_type(:is_pid), do: :pid
  defp tested_type(:is_reference), do: :reference
  defp tested_type(:is_nil), do: nil
  defp tested_type(:is_list), do: :list
  defp tested_type(:is_nonempty_list), do: :cons
  defp tested_type(:is_tuple), do: :tuple
  defp tested_type(:is_map), do: :map
  defp tested_type(:is_function), do: :function
  defp tested_type(:is_port), do: :port
  defp tested_type(_), do: :unknown

  defp equality({:literal, a}, {:literal, b}, expected, st),
    do: if(a === b == expected, do: st, else: nil)

  defp equality(a, {:literal, :ok}, expected, st), do: verdict_check(a, expected, st)
  defp equality({:literal, :ok}, b, expected, st), do: verdict_check(b, expected, st)
  defp equality(a, b, true, st), do: equate(st, a, b)
  defp equality(_, _, false, st), do: st

  defp verdict_check({:verdict, _at, obligations} = term, true, st),
    do: st |> ensure(obligations) |> equate(term, {:literal, :ok})

  defp verdict_check({:verdict, _, _} = term, false, st), do: equate(st, term, :error_result)
  defp verdict_check(term, true, st), do: equate(st, term, {:literal, :ok})
  defp verdict_check(_, false, st), do: st

  defp guard({:verdict, _, _} = term, :tuple, false, st), do: verdict_check(term, true, st)
  defp guard({:verdict, _, _} = term, :tuple, true, st), do: verdict_check(term, false, st)

  defp guard(term, tested, pass, st) do
    known = type(st, term)

    case type_overlap(known, tested) do
      :unknown -> if(pass and tested != :unknown, do: put_type(st, term, tested), else: st)
      :subset -> if(pass, do: st, else: nil)
      :disjoint -> if(pass, do: nil, else: st)
    end
  end

  defp type_overlap(:unknown, _), do: :unknown
  defp type_overlap(_, :unknown), do: :unknown
  defp type_overlap(same, same), do: :subset
  defp type_overlap(known, :list) when known in [:cons, nil], do: :subset
  defp type_overlap(known, :number) when known in [:integer, :float], do: :subset
  defp type_overlap(:binary, :bitstring), do: :subset
  defp type_overlap(:list, tested) when tested in [:cons, nil], do: :unknown
  defp type_overlap(:number, tested) when tested in [:integer, :float], do: :unknown
  defp type_overlap(:bitstring, :binary), do: :unknown
  defp type_overlap(_, _), do: :disjoint

  defp put_type(st, term, kind), do: %{st | types: Map.put(st.types, term, kind)}

  defp equate(st, term, {:literal, value} = literal)
       when is_atom(value) or is_number(value) or is_bitstring(value),
       do: %{st | equal: Map.put(st.equal, term, literal)}

  defp equate(st, {:verdict, _, _} = term, :error_result),
    do: %{st | equal: Map.put(st.equal, term, {:error_result, term})}

  defp equate(st, {:exception, _, _} = term, :error_result),
    do: %{st | equal: Map.put(st.equal, term, :error_result)}

  defp equate(st, {:unknown, _, _} = term, :error_result),
    do: %{st | equal: Map.put(st.equal, term, :error_result)}

  defp equate(st, _term, _value), do: st

  defp ensure(st, obligations),
    do: %{st | safe: Enum.reduce(obligations, st.safe, &MapSet.put(&2, &1))}

  defp type(st, term) do
    case resolve(st, term) do
      {:literal, []} -> nil
      {:literal, t} when is_atom(t) -> :atom
      {:literal, t} when is_integer(t) -> :integer
      {:literal, t} when is_float(t) -> :float
      {:literal, t} when is_binary(t) -> :binary
      {:literal, t} when is_bitstring(t) -> :bitstring
      {:literal, t} when is_tuple(t) -> :tuple
      {:literal, t} when is_map(t) -> :map
      {:literal, [_ | _]} -> :cons
      {:tuple, _} -> :tuple
      {:cons, _, _} -> :cons
      :error_result -> :tuple
      {:error_result, _} -> :tuple
      other -> Map.get(st.types, other, :unknown)
    end
  end

  defp safe?(st, term) do
    MapSet.member?(st.safe, {:safe, term}) or type(st, term) in @safe_types or
      (type(st, term) == :cons and MapSet.member?(st.safe, {:safe, {:field, term, :head}}) and
         MapSet.member?(st.safe, {:safe, {:field, term, :tail}})) or
      (type(st, term) == :tuple and MapSet.member?(st.safe, {:prefix, term, {:size, term}}))
  end

  defp prefix?(st, tuple, count) do
    resolve(st, count) == {:literal, 0} or MapSet.member?(st.safe, {:prefix, tuple, count}) or
      (MapSet.member?(st.safe, {:safe, {:element, tuple, count}}) and
         MapSet.member?(st.safe, {:prefix, tuple, {:previous, count}}))
  end

  defp contains?(term, wanted) when term == wanted, do: true
  defp contains?({:tuple, values}, wanted), do: Enum.any?(values, &contains?(&1, wanted))

  defp contains?({:cons, head, tail}, wanted),
    do: contains?(head, wanted) or contains?(tail, wanted)

  defp contains?({:field, parent, _}, wanted), do: contains?(parent, wanted)
  defp contains?({:element, parent, _}, wanted), do: contains?(parent, wanted)
  defp contains?({:error_result, source}, wanted), do: contains?(source, wanted)

  defp contains?({:verdict, _, obligations}, wanted),
    do:
      Enum.any?(obligations, fn
        {:safe, value} -> contains?(value, wanted)
        {:prefix, value, _} -> contains?(value, wanted)
      end)

  defp contains?(_, _), do: false
end
