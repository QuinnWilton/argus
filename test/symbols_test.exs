defmodule Argus.SymbolsTest do
  use ExUnit.Case, async: true

  alias Argus.{InstrId, Symbols}

  setup do
    # The ETS tables die with the test process.
    %{symbols: Symbols.new()}
  end

  test "the same binary always gets the same id, and resolves back", %{symbols: s} do
    id = Symbols.intern(s, "Mod:f/1")
    assert Symbols.intern(s, "Mod:f/1") == id
    assert Symbols.intern(s, "Mod:g/1") != id
    assert Symbols.resolve(s, id) == "Mod:f/1"
  end

  test "parallel interning of the same binaries agrees on ids", %{symbols: s} do
    binaries = for i <- 1..500, do: "sym#{i}"

    results =
      1..8
      |> Task.async_stream(fn _ -> Enum.map(binaries, &Symbols.intern(s, &1)) end, ordered: true)
      |> Enum.map(fn {:ok, ids} -> ids end)

    assert Enum.uniq(results) |> length() == 1
    assert Enum.uniq(hd(results)) |> length() == 500
  end

  test "instr_id/2 parses once and caches; non-IDs are :error", %{symbols: s} do
    id = Symbols.intern(s, "Demo:run/2#7")

    assert {:ok, %InstrId{module: "Demo", func: "run", arity: 2, idx: 7}} =
             Symbols.instr_id(s, id)

    assert Symbols.instr_id(s, id) == Symbols.instr_id(s, id)
    assert :error = Symbols.instr_id(s, Symbols.intern(s, "dynamic"))
  end

  test "a custom store is used for both directions" do
    defmodule MapStore do
      @behaviour Symbols.Store
      def intern(agent, binary),
        do:
          Agent.get_and_update(agent, fn {f, r, n} ->
            case Map.fetch(f, binary) do
              {:ok, id} -> {id, {f, r, n}}
              :error -> {n, {Map.put(f, binary, n), Map.put(r, n, binary), n + 1}}
            end
          end)

      def resolve(agent, id), do: Agent.get(agent, fn {_f, r, _n} -> Map.fetch!(r, id) end)
    end

    {:ok, agent} = Agent.start_link(fn -> {%{}, %{}, 1} end)
    s = Symbols.new(MapStore, agent)
    assert Symbols.intern(s, "a") == 1
    assert Symbols.intern(s, "b") == 2
    assert Symbols.intern(s, "a") == 1
    assert Symbols.resolve(s, 2) == "b"
  end
end
