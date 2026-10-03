defmodule Argus.Extractors.PathTraversal.Flow do
  @moduledoc false

  alias Argus.Extractor.Helpers
  alias Argus.Extractors.ParamFlow.Propagators
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  @max_depth 64
  @type paths :: {[{String.t(), boolean(), boolean()}], boolean()}

  # {source field, has been joined, basename remains the final component}.
  # Unknown alternatives are retained separately and cannot establish safety.
  @spec value(map(), non_neg_integer(), term()) :: paths()
  def value(ctx, at, operand), do: value(ctx, at, operand, %{})

  defp value(ctx, at, operand, seen) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] ->
        key = {ctx.func, at, reg}

        if map_size(seen) >= @max_depth or Map.has_key?(seen, key) do
          {[], true}
        else
          seen = Map.put(seen, key, true)

          ctx.instrs
          |> Reaching.sources(at, reg)
          |> Enum.map(fn
            {:param, param} -> argument(ctx, param, seen)
            writer -> written(ctx, writer, reg, seen)
          end)
          |> merge()
        end

      _ ->
        {[], false}
    end
  end

  defp argument(ctx, param, seen) do
    case Map.get(ctx.args, param) do
      {caller, at, reg} -> value(caller, at, reg, seen)
      nil -> {[], false}
    end
  end

  defp written(ctx, at, reg, seen) do
    instr = Reaching.at(ctx.instrs, at)

    case Instr.copy_source(instr, reg) do
      nil -> made(ctx, at, reg, instr, seen)
      source -> value(ctx, at, source, seen)
    end
  end

  defp made(ctx, at, reg, instr, seen) do
    identity = SecurityValues.identity_at(ctx.instrs, at + 1, reg)

    case source(ctx, identity) do
      nil -> derived(ctx, at, reg, instr, seen)
      origin -> {[{origin, false, false}], false}
    end
  end

  defp source(ctx, {:field, {:param, param}, :map, :client_name}) do
    case root(ctx, param) do
      nil -> nil
      func -> func <> ":param1.client_name"
    end
  end

  defp source(_ctx, _identity), do: nil

  defp root(ctx, param) do
    cond do
      param == 1 and MapSet.member?(ctx.sources, ctx.func) ->
        ctx.func

      Map.has_key?(ctx.args, param) ->
        {caller, at, reg} = Map.fetch!(ctx.args, param)

        case SecurityValues.identity_at(caller.instrs, at, reg) do
          {:param, outer} -> root(caller, outer)
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp derived(ctx, at, reg, instr, seen) do
    case called(instr) do
      {:ok, mod, :basename, arity} when mod in [Path, :filename] and arity in [1, 2] ->
        {paths, unknown?} = value(ctx, at, {:x, 0}, seen)

        safe? =
          Instr.tail_call?(instr) or
            SecurityValues.safe_at?(ctx.instrs, at + 1, reg, "path_basename")

        {Enum.map(paths, fn {source, joined, _} -> {source, joined, safe?} end), unknown?}

      {:ok, Path, :join, 1} ->
        join_list(ctx, at, seen)

      {:ok, Path, :join, 2} ->
        join(ctx, [{at, {:x, 0}}, {at, {:x, 1}}], seen)

      {:ok, Path, :expand, arity} when arity in [1, 2] ->
        0..(arity - 1)
        |> Enum.map(&value(ctx, at, {:x, &1}, seen))
        |> merge()
        |> unbounded()

      {:ok, mod, fun, arity} ->
        call(ctx, at, {mod, fun, arity}, seen)

      :none ->
        structure(ctx, at, instr, seen)
    end
  end

  defp called(instr) do
    case Helpers.match_remote_call(instr) do
      :none -> Helpers.match_local_call(instr)
      call -> call
    end
  end

  defp call(ctx, at, {mod, fun, arity}, seen) do
    target = InstrId.func_id(mod, fun, arity)

    case Map.fetch(ctx.functions, target) do
      {:ok, instrs} ->
        args = Map.new(0..(arity - 1)//1, &{&1, {ctx, at, {:x, &1}}})
        callee = %{ctx | func: target, instrs: instrs, args: args}
        returns(callee, seen)

      :error ->
        positions = Propagators.positions(inspect(mod), Atom.to_string(fun), arity)

        if positions == nil do
          {inputs, unknown?} =
            0..(arity - 1)//1
            |> Enum.map(&value(ctx, at, {:x, &1}, seen))
            |> merge()

          {[], unknown? or inputs != []}
        else
          positions
          |> Enum.map(&value(ctx, at, {:x, &1}, seen))
          |> merge()
          |> unbounded()
        end
    end
  end

  defp returns(ctx, seen) do
    ctx.instrs
    |> Enum.with_index()
    |> Enum.flat_map(fn {instr, at} ->
      cond do
        instr == :return -> [value(ctx, at, {:x, 0}, seen)]
        Instr.tail_call?(instr) -> [derived(ctx, at, {:x, 0}, instr, seen)]
        true -> []
      end
    end)
    |> merge()
  end

  defp structure(ctx, at, instr, seen) do
    if is_tuple(instr) and elem(instr, 0) in [:bs_create_bin, :put_list] do
      instr
      |> Instr.uses()
      |> Enum.map(&value(ctx, at, &1, seen))
      |> merge()
      |> unbounded()
    else
      {[], false}
    end
  end

  defp join_list(ctx, at, seen) do
    ctx
    |> components(at, {:x, 0}, seen)
    |> Enum.map(fn
      :unknown -> {[], true}
      parts -> join(ctx, parts, seen)
    end)
    |> merge()
  end

  defp join(ctx, parts, seen) do
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn {{at, operand}, index} ->
      {paths, unknown?} = value(ctx, at, operand, seen)

      {Enum.map(paths, fn {source, _, safe?} -> {source, true, safe? and index == last} end),
       unknown?}
    end)
    |> merge()
  end

  defp components(ctx, at, operand, seen) do
    reg = Instr.register(operand)
    key = {:list, ctx.func, at, reg}

    cond do
      reg == nil ->
        [[]]

      map_size(seen) >= @max_depth or Map.has_key?(seen, key) ->
        [:unknown]

      match?({:literal, values} when is_list(values), reg) ->
        {:literal, values} = reg
        [Enum.map(values, &{at, {:literal, &1}})]

      match?({:literal, _}, reg) ->
        [:unknown]

      true ->
        seen = Map.put(seen, key, true)

        ctx.instrs
        |> Reaching.sources(at, reg)
        |> Enum.flat_map(fn
          {:param, _} -> [:unknown]
          writer -> list_writer(ctx, writer, reg, seen)
        end)
    end
  end

  defp list_writer(ctx, at, reg, seen) do
    instr = Reaching.at(ctx.instrs, at)

    case Instr.copy_source(instr, reg) do
      nil ->
        case instr do
          {:put_list, head, tail, _} ->
            Enum.map(components(ctx, at, tail, seen), fn
              :unknown -> :unknown
              parts -> [{at, head} | parts]
            end)

          _ ->
            [:unknown]
        end

      source ->
        components(ctx, at, source, seen)
    end
  end

  defp merge(results) do
    {paths, unknown?} =
      Enum.reduce(results, {[], false}, fn {paths, unknown?}, {acc, uncertain?} ->
        {paths ++ acc, unknown? or uncertain?}
      end)

    {Enum.uniq(paths), unknown?}
  end

  defp unbounded({paths, unknown?}),
    do: {Enum.map(paths, fn {source, joined, _} -> {source, joined, false} end), unknown?}
end
