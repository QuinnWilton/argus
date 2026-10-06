defmodule Argus.Extractors.EtfAllocation.Prefix do
  @moduledoc """
  Small must-value interpreter for binary-prefix proofs.

  Ordinary identities come from SecurityValues. Binary match contexts additionally
  retain their original binary and a known bit position; restoring a saved zero
  position makes bs_get_tail the original binary again. Unsupported mutations lose
  the position. A second solve may assume one exact identity begins with the
  compressed ETF prefix, pruning only matches decided by those two known bytes.
  Unknown instructions, lengths and branches retain uncertainty.
  """

  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @prefix 33_616
  @max_visits 32

  @doc "States before reachable instructions, or :unknown if a conservative budget is exhausted."
  @spec states(map() | nil, [term()], term() | nil) :: map() | :unknown
  def states(cfg, instrs, compressed \\ nil)
  def states(nil, _instrs, _compressed), do: :unknown

  def states(cfg, instrs, compressed) do
    entry = %{
      regs: Map.new(0..(cfg.arity - 1)//1, &{{:x, &1}, {:param, &1}}),
      positions: %{}
    }

    case solve([cfg.entry], %{cfg.entry => entry}, %{}, cfg, instrs, compressed) do
      :unknown -> :unknown
      incoming -> snapshots(incoming, cfg, instrs)
    end
  end

  @doc "Exact value of an operand in a state, including restored full binary tails."
  @spec value(map(), term()) :: term() | nil
  def value(state, operand) do
    case Instr.register(operand) do
      {kind, _} = reg when kind in [:x, :y] -> Map.get(state.regs, reg)
      {kind, literal} when kind in [:literal, :atom, :integer, :float] -> {:literal, literal}
      nil -> {:literal, []}
      _ -> nil
    end
  end

  defp solve([], incoming, _visits, _cfg, _instrs, _compressed), do: incoming

  defp solve([id | rest], incoming, visits, cfg, instrs, compressed) do
    count = Map.get(visits, id, 0)

    if count >= @max_visits do
      :unknown
    else
      %{range: {first, last}, succs: succs} = Map.fetch!(cfg.blocks, id)
      before = Enum.reduce(first..(last - 1)//1, Map.fetch!(incoming, id), &step(instrs, &1, &2))
      instr = Reaching.at(instrs, last)
      outcome = outcome(instr, before, compressed)
      after_instr = step(instrs, last, before)

      {incoming, changed} =
        for {next, edge} <- succs,
            allowed?(edge, outcome),
            reduce: {incoming, []} do
          {ins, changed} ->
            out = failure_state(after_instr, instr, edge)
            merged = if Map.has_key?(ins, next), do: meet(Map.fetch!(ins, next), out), else: out

            if Map.get(ins, next) == merged,
              do: {ins, changed},
              else: {Map.put(ins, next, merged), [next | changed]}
        end

      solve(
        Enum.uniq(rest ++ Enum.reverse(changed)),
        incoming,
        Map.put(visits, id, count + 1),
        cfg,
        instrs,
        compressed
      )
    end
  end

  defp snapshots(incoming, cfg, instrs) do
    Enum.reduce(incoming, %{}, fn {id, entry}, acc ->
      %{range: {first, last}} = Map.fetch!(cfg.blocks, id)

      {_, acc} =
        Enum.reduce(first..last, {entry, acc}, fn at, {state, acc} ->
          {step(instrs, at, state), Map.put(acc, at, state)}
        end)

      acc
    end)
  end

  defp meet(left, right) do
    %{regs: common(left.regs, right.regs), positions: common(left.positions, right.positions)}
  end

  defp common(left, right),
    do: Map.new(left, fn pair -> pair end) |> Map.filter(fn {k, v} -> Map.get(right, k) == v end)

  defp step(instrs, at, state) do
    instr = Reaching.at(instrs, at)
    kept = Map.reject(state.regs, fn {reg, _} -> Instr.clobbers?(instr, reg) end)

    regs =
      Enum.reduce(Instr.defs(instr), kept, fn reg, acc ->
        identity =
          case Instr.copy_source(instr, reg) do
            nil -> made(instrs, at, instr, reg, state)
            source -> value(state, source)
          end

        if identity == nil, do: acc, else: Map.put(acc, reg, identity)
      end)

    %{regs: regs, positions: positions(instr, at, state)}
  end

  defp made(_instrs, at, {:test, :bs_start_match3, _, _, [src], _}, _reg, state),
    do: context(value(state, src), at)

  defp made(_instrs, at, {:bs_start_match4, _, _, src, _}, _reg, state),
    do: context(value(state, src), at)

  defp made(_instrs, _at, {:bs_get_position, ctx, _, _}, _reg, state) do
    with {:context, id, _origin} <- value(state, ctx),
         offset when is_integer(offset) <- Map.get(state.positions, id),
         do: {:position, id, offset},
         else: (_ -> nil)
  end

  defp made(_instrs, _at, {:bs_get_tail, ctx, _, _}, _reg, state) do
    with {:context, id, origin} <- value(state, ctx),
         0 <- Map.get(state.positions, id),
         do: origin,
         else: (_ -> nil)
  end

  defp made(instrs, at, instr, reg, _state) do
    if Instr.call?(instr), do: {:call, at}, else: SecurityValues.identity_at(instrs, at + 1, reg)
  end

  defp context(nil, _at), do: nil
  defp context(origin, at), do: {:context, at, origin}

  defp positions({:test, :bs_start_match3, _, _, [_], _}, at, state),
    do: Map.put(state.positions, at, 0)

  defp positions({:bs_start_match4, _, _, _, _}, at, state),
    do: Map.put(state.positions, at, 0)

  defp positions({:bs_set_position, ctx, saved}, _at, state) do
    case {value(state, ctx), value(state, saved)} do
      {{:context, id, _}, {:position, id, offset}} -> Map.put(state.positions, id, offset)
      {{:context, id, _}, _} -> Map.delete(state.positions, id)
      _ -> state.positions
    end
  end

  defp positions({:bs_match, _, ctx, {:commands, commands}}, _at, state) do
    case value(state, ctx) do
      {:context, id, _} ->
        offset = Enum.reduce(commands, Map.get(state.positions, id), &advance/2)

        if offset == nil,
          do: Map.delete(state.positions, id),
          else: Map.put(state.positions, id, offset)

      _ ->
        state.positions
    end
  end

  defp positions(instr, _at, state) do
    # Copies and non-mutating context observations preserve positions. All other
    # uses of a match context are unknown unless interpreted explicitly above.
    if context_observation?(instr) do
      state.positions
    else
      Enum.reduce(Instr.uses(instr), state.positions, fn reg, positions ->
        case value(state, reg) do
          {:context, id, _} -> Map.delete(positions, id)
          _ -> positions
        end
      end)
    end
  end

  defp context_observation?({:bs_get_position, _, _, _}), do: true
  defp context_observation?({:bs_get_tail, _, _, _}), do: true
  defp context_observation?({:bif, :byte_size, _, _, _}), do: true
  defp context_observation?({:gc_bif, :byte_size, _, _, _, _}), do: true

  defp context_observation?(instr),
    do:
      Instr.defs(instr) != [] and
        Enum.all?(Instr.defs(instr), &(Instr.copy_source(instr, &1) != nil)) and
        Instr.known?(instr) and
        not Instr.call?(instr)

  defp advance(_command, nil), do: nil
  defp advance({:ensure_at_least, _, _}, offset), do: offset
  defp advance({:"=:=", _, bits, _}, offset) when offset + bits <= 16, do: offset + bits
  defp advance(_command, _offset), do: nil

  defp outcome(_instr, _state, nil), do: :unknown

  defp outcome({:test, :bs_start_match3, _, _, [src], _}, state, compressed),
    do: if(value(state, src) == compressed, do: :pass, else: :unknown)

  defp outcome({:bs_start_match4, _, _, src, _}, state, compressed),
    do: if(value(state, src) == compressed, do: :pass, else: :unknown)

  defp outcome({:bs_match, _, ctx, {:commands, commands}}, state, compressed) do
    case value(state, ctx) do
      {:context, id, ^compressed} -> check(commands, Map.get(state.positions, id))
      _ -> :unknown
    end
  end

  defp outcome(_instr, _state, _compressed), do: :unknown

  defp check(_commands, nil), do: :unknown
  defp check([], _offset), do: :pass

  defp check([{:ensure_at_least, bits, 8} | rest], offset) when bits <= 16 - offset,
    do: check(rest, offset)

  defp check([{:"=:=", _, bits, expected} | rest], offset)
       when bits > 0 and bits <= 16 - offset do
    <<_::size(^offset), actual::size(^bits), _::bitstring>> = <<@prefix::16>>
    if actual == expected, do: check(rest, offset + bits), else: :fail
  end

  defp check(_commands, _offset), do: :unknown

  defp allowed?(:branch_fail, :pass), do: false
  defp allowed?(:branch_pass, :fail), do: false
  defp allowed?(_edge, _outcome), do: true

  defp failure_state(state, {:bs_match, _, ctx, _}, :branch_fail) do
    case value(state, ctx) do
      {:context, id, _} -> %{state | positions: Map.delete(state.positions, id)}
      _ -> state
    end
  end

  defp failure_state(state, _instr, _edge), do: state
end
