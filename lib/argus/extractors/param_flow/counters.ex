defmodule Argus.Extractors.ParamFlow.Counters do
  @moduledoc """
  Where a closure reads the position counter of the element it is handed.

  `for {t, i} <- Enum.with_index(ts, 1), do: ...` compiles to an
  `Enum.reduce/3` over the pairs `Enum.with_index/2` returns, with a
  closure that takes each pair as its first parameter. Its `i` counts
  from the literal `1` whatever `ts` holds, so it is made of none of the
  caller's data: sql names its decoder strides `:"decode_\#{i}"`, and the
  atoms are the same `decode_1`, `decode_2`, ... on every call. A
  projection of the counter out of the pair is therefore derived from no
  parameter (`Argus.Extractors.ParamFlow`) and, by data, made of nothing
  (`Argus.Extractors.Dependence`). The element beside it stays the
  caller's.

  A closure counts only where nothing else can hand it a first
  parameter: every `make_fun3` of it builds a fun that no instruction
  reads before the higher-order call that takes it
  (`Propagators.element_call/1`), over pairs a counted enumeration
  returned (`Propagators.counted_call/1`) with literal offsets, and no
  local call runs it directly. The counter is still as large as the
  enumerable is long; it is the content, not the length, that it does not
  carry.
  """

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.Instr
  alias Argus.InstrId

  @doc """
  The closures of the module whose first parameter is always a pair of an
  element and its counter: `%{func_id => the counter's field}`. Every
  `make_fun3` of a closure is in the module, so this reads all of its
  functions; the query graph hands each function's entry to
  `Argus.Extractors.Dependence`, which extracts one function at a time,
  as `counted_closures`.
  """
  @spec closures(Argus.Extractor.module_data()) :: %{String.t() => non_neg_integer()}
  def closures(module_data), do: counted_closures(module_data)

  @doc """
  The instructions of a counted closure that project the counter (its
  field `field`) out of its first parameter; none for any other function
  (`nil`).
  """
  @spec projections([term()], non_neg_integer() | nil) :: MapSet.t(non_neg_integer())
  def projections(instrs, field), do: instrs |> counter_projections(field) |> MapSet.new()

  # %{closure => the counter's field}: the closures every make_fun3 of
  # which is handed straight to a higher-order call over counted pairs.
  defp counted_closures(%{module: mod, functions: functions}) do
    {sites, called} =
      Enum.reduce(functions, {[], MapSet.new()}, fn {:function, _name, _arity, _entry, instrs},
                                                    acc ->
        instrs
        |> Enum.with_index()
        |> Enum.reduce(acc, fn
          {{:make_fun3, {^mod, cname, carity}, _index, _uniq, dst, _env}, idx}, {sites, called} ->
            site = {InstrId.func_id(mod, cname, carity), counted_site(instrs, idx + 1, dst)}
            {[site | sites], called}

          {instr, _idx}, {sites, called} ->
            case Helpers.match_local_call(instr) do
              {:ok, m, f, a} -> {sites, MapSet.put(called, InstrId.func_id(m, f, a))}
              :none -> {sites, called}
            end
        end)
      end)

    sites
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {closure, fields} ->
      case Enum.uniq(fields) do
        [field] when is_integer(field) ->
          if MapSet.member?(called, closure), do: [], else: [{closure, field}]

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  # The counter's field of the pairs the fun built into `dst` runs on, or
  # nil: the instructions up to the higher-order call that takes it fall
  # through to it, and neither read nor write `dst`.
  defp counted_site(instrs, from, dst) do
    dst = Instr.register(dst)

    instrs
    |> Enum.drop(from)
    |> Enum.with_index(from)
    |> Enum.reduce_while(nil, fn {instr, idx}, nil ->
      with {:ok, mod, fun, arity} <- Helpers.match_remote_call(instr),
           {:ok, {coll_pos, fun_pos}} <- Propagators.element_call({mod, fun, arity}),
           true <- dst == {:x, fun_pos} do
        {:halt, counter_field(instrs, idx, {:x, coll_pos})}
      else
        _ -> if passes?(instr, dst), do: {:cont, nil}, else: {:halt, nil}
      end
    end)
  end

  defp passes?(instr, dst) do
    Instr.known?(instr) and Instr.falls_through?(instr) and Instr.targets(instr) == [] and
      not Instr.call?(instr) and not Instr.tail_call?(instr) and
      dst not in Instr.uses(instr) and dst not in Instr.defs(instr)
  end

  # The counter's field of the pairs `reg` holds at `idx`, when a counted
  # enumeration with literal offsets returned them.
  defp counter_field(instrs, idx, reg) do
    with {:ok, mfa, at} <- Resolve.call_result_origin(instrs, idx, reg),
         {:ok, {field, literals}} <- Propagators.counted_call(mfa),
         true <- Enum.all?(literals, &integer_literal?(instrs, at, {:x, &1})) do
      field
    else
      _ -> nil
    end
  end

  defp integer_literal?(instrs, idx, reg) do
    Resolve.trace(instrs, idx, reg, false, fn
      {_at, {:move, {:integer, _n}, _dst}}, _follow -> true
      _writer, _follow -> false
    end)
  end

  # The projections of element `field` out of the first parameter itself.
  defp counter_projections(_instrs, nil), do: []

  defp counter_projections(instrs, field) do
    instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {instr, idx} ->
      case projection(instr) do
        {src, ^field} ->
          if Resolve.writers(instrs, idx, src) == [{:param, 0}], do: [idx], else: []

        _ ->
          []
      end
    end)
  end

  defp projection({:get_tuple_element, src, n, _dst}) when is_integer(n), do: {src, n}

  defp projection({:bif, :element, _fail, [{:integer, n}, src], _dst}) when n >= 1,
    do: {src, n - 1}

  defp projection({:gc_bif, :element, _fail, _live, [{:integer, n}, src], _dst}) when n >= 1,
    do: {src, n - 1}

  defp projection(_instr), do: nil
end
