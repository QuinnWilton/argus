defmodule Argus.Extractors.SecurityValues.Binary do
  @moduledoc "Must-binary registers, including the compiler's guarded to_string fast path."

  alias Argus.Extractor.Helpers
  alias Argus.Extractors.SecurityValues
  alias Argus.Instr
  alias Argus.Instr.Reaching

  @doc "Registers known to be binaries before each instruction; uncertainty yields no proof."
  @spec types(map() | nil, [term()]) :: map()
  def types(nil, _instrs), do: %{}

  def types(cfg, instrs) do
    regs = instrs |> Enum.flat_map(&(Instr.uses(&1) ++ Instr.defs(&1))) |> Enum.uniq()

    case solve([cfg.entry], %{cfg.entry => MapSet.new()}, %{}, cfg, instrs, regs) do
      nil ->
        %{}

      incoming ->
        Enum.reduce(incoming, %{}, fn {id, state}, acc ->
          %{range: {first, last}} = Map.fetch!(cfg.blocks, id)

          {_, acc} =
            Enum.reduce(first..last, {state, acc}, fn at, {state, acc} ->
              {step(Reaching.at(instrs, at), state), Map.put(acc, at, state)}
            end)

          acc
        end)
    end
  end

  defp solve([], incoming, _counts, _cfg, _instrs, _regs), do: incoming

  defp solve([id | rest], incoming, counts, cfg, instrs, regs) do
    if Map.get(counts, id, 0) >= 32 do
      nil
    else
      %{range: {first, last}, succs: succs} = Map.fetch!(cfg.blocks, id)

      state =
        Enum.reduce(first..last, Map.fetch!(incoming, id), &step(Reaching.at(instrs, &1), &2))

      {incoming, changed} =
        Enum.reduce(succs, {incoming, []}, fn {next, edge}, {incoming, changed} ->
          out = refine(instrs, last, edge, state, regs)

          merged =
            case Map.fetch(incoming, next) do
              {:ok, old} -> MapSet.intersection(old, out)
              :error -> out
            end

          if Map.get(incoming, next) == merged,
            do: {incoming, changed},
            else: {Map.put(incoming, next, merged), [next | changed]}
        end)

      solve(
        Enum.uniq(rest ++ changed),
        incoming,
        Map.update(counts, id, 1, &(&1 + 1)),
        cfg,
        instrs,
        regs
      )
    end
  end

  defp refine(instrs, at, :branch_pass, state, regs) do
    case Reaching.at(instrs, at) do
      {:test, :is_binary, _, [operand]} ->
        checked = Instr.register(operand)
        identity = SecurityValues.identity_at(instrs, at, checked)

        Enum.reduce(regs, MapSet.put(state, checked), fn reg, acc ->
          if identity != nil and SecurityValues.identity_at(instrs, at, reg) == identity,
            do: MapSet.put(acc, reg),
            else: acc
        end)

      _ ->
        state
    end
  end

  defp refine(_instrs, _at, _edge, state, _regs), do: state

  @doc false
  @spec step(Instr.instr(), MapSet.t(Instr.reg())) :: MapSet.t(Instr.reg())
  def step(instr, state) do
    kept = MapSet.reject(state, &Instr.clobbers?(instr, &1))

    Enum.reduce(Instr.defs(instr), kept, fn reg, acc ->
      known? =
        case Instr.copy_source(instr, reg) do
          nil -> binary_result?(instr) or binary_identity?(instr, state)
          source -> binary_operand?(source, state)
        end

      if known?, do: MapSet.put(acc, reg), else: acc
    end)
  end

  # String.Chars is a user-extensible protocol. Its binary implementation is
  # identity, but an arbitrary implementation need not honor a binary spec.
  defp binary_identity?(instr, state) do
    Helpers.match_remote_call(instr) == {:ok, String.Chars, :to_string, 1} and
      MapSet.member?(state, {:x, 0})
  end

  defp binary_operand?({:literal, literal}, _state), do: is_binary(literal)
  defp binary_operand?(source, state), do: MapSet.member?(state, Instr.register(source))

  @doc "Known operations whose normal result is a binary, independent of argument contents."
  @spec binary_result?(Instr.instr()) :: boolean()
  def binary_result?({:bs_create_bin, _, _, _, _, _, _}), do: true

  def binary_result?(instr) do
    case Helpers.match_remote_call(instr) do
      {:ok, mod, fun, 1}
      when {mod, fun} in [
             {Atom, :to_string},
             {Integer, :to_string},
             {String, :downcase},
             {String, :upcase},
             {IO, :iodata_to_binary},
             {:erlang, :iolist_to_binary},
             {Plug.HTML, :html_escape},
             {Phoenix.HTML, :safe_to_string}
           ] ->
        true

      _ ->
        false
    end
  end
end
