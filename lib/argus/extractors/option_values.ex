defmodule Argus.Extractors.OptionValues do
  @moduledoc """
  Atoms made of an option's value.

  An option list is how a caller configures a library: `[{name, "srv"},
  {encoding, "utf-8"}]`, or a map or keyword list under literal atom
  keys. A string a function makes an atom of is an option's value when
  it is, on every path that reaches the conversion, the value of such an
  entry:

  - the second element of a list's pair whose first element the
    function compares to literal atoms: mochiweb's
    `parse_options([{name, L} | Rest], State)`, a `select_val` or an
    `is_eq_exact` on the pair's first element, or an `is_tagged_tuple`
    on the pair; or
  - what a keyed lookup answers under a literal atom key:
    `proplists:get_value(name, Opts)`, `maps:get(name, Opts)`,
    `Keyword.get(opts, :name)`, `Map.get(opts, :name)`.

  The value is still the caller's, and a caller may fill an option from
  anywhere. What the shape says is that the library takes it as
  configuration, which its user sets when starting it, more often than
  as data a request carries: a rule reads it as a reason to step a
  finding down, not to drop it.

  ## Emitted facts

  - `option_value(id, func)` — the atom created at `id` is made of an
    option's value
  """

  @behaviour Argus.Extractor

  alias Argus.Extractor.Helpers
  alias Argus.Extractor.Resolve
  alias Argus.Instr
  alias Argus.Instr.Reaching
  alias Argus.InstrId

  import Argus.Extractor.Facts, only: [add_fact: 3]
  import Argus.Instr, only: [slot: 1]

  @atom_calls [
    {:erlang, :list_to_atom, 1},
    {:erlang, :binary_to_atom, 1},
    {:erlang, :binary_to_atom, 2},
    {String, :to_atom, 1}
  ]

  # Keyed lookups: the position of the key among the call's arguments.
  @lookups %{
    {:proplists, :get_value, 2} => 0,
    {:proplists, :get_value, 3} => 0,
    {:maps, :get, 2} => 0,
    {:maps, :get, 3} => 0,
    {Keyword, :get, 2} => 1,
    {Keyword, :get, 3} => 1,
    {Keyword, :fetch!, 2} => 1,
    {Map, :get, 2} => 1,
    {Map, :get, 3} => 1,
    {Map, :fetch!, 2} => 1
  }

  @impl true
  def relations, do: [:option_value]

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(%{module: mod, functions: functions}) do
    for {:function, name, arity, _entry, instrs} <- functions,
        {instr, idx} <- Enum.with_index(instrs),
        {:ok, m, f, a} <- [Helpers.match_remote_call(instr)],
        {m, f, a} in @atom_calls,
        option_value?(instrs, idx),
        reduce: %{} do
      acc ->
        func = InstrId.func_id(mod, name, arity)
        add_fact(acc, :option_value, [InstrId.mint(func, idx), func])
    end
  end

  defp option_value?(instrs, idx) do
    case writes(instrs, idx, {:x, 0}) do
      [_ | _] = defs -> Enum.all?(defs, fn {at, _reg} -> option_def?(instrs, at) end)
      [] -> false
    end
  end

  # The instructions that wrote what `reg` holds at `idx`, through copies,
  # each with the register it wrote; empty when a parameter may reach it.
  defp writes(instrs, idx, reg), do: writes(instrs, [{idx, slot(reg)}], %{}, [])

  defp writes(_instrs, [], _seen, acc), do: acc

  defp writes(instrs, [{idx, reg} = here | rest], seen, acc) do
    if Map.has_key?(seen, here) do
      writes(instrs, rest, seen, acc)
    else
      seen = Map.put(seen, here, true)
      sources = Reaching.sources(instrs, idx, reg)

      if Enum.any?(sources, &match?({:param, _}, &1)) do
        []
      else
        {next, acc} =
          Enum.reduce(sources, {rest, acc}, fn at, {next, acc} ->
            instr = Reaching.at(instrs, at)

            case Instr.copy_source(instr, reg) do
              {kind, _} = from when kind in [:x, :y] -> {[{at, slot(from)} | next], acc}
              _ -> {next, [{at, reg} | acc]}
            end
          end)

        writes(instrs, next, seen, acc)
      end
    end
  end

  defp option_def?(instrs, at) do
    case Reaching.at(instrs, at) do
      {:get_tuple_element, pair, 1, _dst} ->
        list_entry?(instrs, at, pair) and keyed_pair?(instrs, at, pair)

      instr ->
        keyed_lookup?(instrs, at, instr)
    end
  end

  # The pair is, on every path, the head of a list.
  defp list_entry?(instrs, at, pair) do
    case writes(instrs, at, pair) do
      [_ | _] = defs -> Enum.all?(defs, fn {d, reg} -> head?(Reaching.at(instrs, d), reg) end)
      [] -> false
    end
  end

  defp head?({:get_list, _src, head, _tail}, reg), do: slot(head) == reg
  defp head?({:get_hd, _src, head}, reg), do: slot(head) == reg
  defp head?(_instr, _reg), do: false

  # Something tests the pair's first element against a literal atom: the
  # pair's own tag test, or a test of its element 0 read from it.
  defp keyed_pair?(instrs, at, pair) do
    pair_defs = Enum.sort(writes(instrs, at, pair))

    instrs
    |> Enum.with_index()
    |> Enum.any?(fn
      {{:test, :is_tagged_tuple, _f, [t, 2, {:atom, _}]}, e} ->
        same_value?(instrs, e, t, pair_defs)

      {{:get_tuple_element, t, 0, key}, e} ->
        same_value?(instrs, e, t, pair_defs) and atom_tested?(instrs, e, slot(key))

      _ ->
        false
    end)
  end

  defp same_value?(instrs, e, reg, defs) do
    slot(reg) != nil and Enum.sort(writes(instrs, e, reg)) == defs
  end

  # The key read at `e` meets a comparison with literal atoms.
  defp atom_tested?(instrs, e, key) do
    instrs
    |> Enum.with_index()
    |> Enum.any?(fn
      {{:select_val, src, _f, {:list, entries}}, s} ->
        slot(src) == key and Enum.any?(entries, &match?({:atom, _}, &1)) and
          defined_at?(instrs, s, src, e)

      {{:test, op, _f, [a, b]}, s} when op in [:is_eq_exact, :is_eq] ->
        cond do
          slot(a) == key and match?({:atom, _}, b) -> defined_at?(instrs, s, a, e)
          slot(b) == key and match?({:atom, _}, a) -> defined_at?(instrs, s, b, e)
          true -> false
        end

      _ ->
        false
    end)
  end

  defp defined_at?(instrs, s, reg, e), do: Enum.map(writes(instrs, s, reg), &elem(&1, 0)) == [e]

  defp keyed_lookup?(instrs, at, instr) do
    with {:ok, m, f, a} <- Helpers.match_remote_call(instr),
         {:ok, pos} <- Map.fetch(@lookups, {m, f, a}),
         {:ok, key} when is_atom(key) <- Resolve.resolve_register(instrs, at, {:x, pos}) do
      true
    else
      _ -> false
    end
  end
end
