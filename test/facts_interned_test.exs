defmodule Argus.FactsInternedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.{Facts, Pipeline, Schema, Symbols}

  defmodule CountingStore do
    @moduledoc false
    # An ETS store that counts `resolve/2` calls per id.
    @behaviour Argus.Symbols.Store

    alias Argus.Symbols.ETS

    def new, do: %{inner: ETS.new(), counts: :ets.new(:counts, [:public])}

    @impl true
    def intern(%{inner: inner}, binary), do: ETS.intern(inner, binary)

    @impl true
    def resolve(%{inner: inner, counts: counts}, id) do
      :ets.update_counter(counts, id, 1, {id, 0})
      ETS.resolve(inner, id)
    end
  end

  setup do
    # The ETS tables die with the test process.
    %{symbols: Symbols.new()}
  end

  test "intern then materialize round-trips a real module's facts", %{symbols: s} do
    {:ok, raw} =
      Pipeline.extract([Argus.Test.Fixtures.MyGenServer], extractors: [Argus.Extractors.OTP])

    interned = Facts.intern(raw, s)

    assert Facts.materialize(interned, s) == raw

    for {_relation, rows} <- interned, row <- rows do
      assert is_tuple(row)
      assert Enum.all?(Tuple.to_list(row), &is_integer/1)
    end
  end

  test "decode/2 over interned rows equals decode/1 over the raw ones", %{symbols: s} do
    {:ok, raw} =
      Pipeline.extract([Argus.Test.Fixtures.MyGenServer], extractors: [Argus.Extractors.OTP])

    assert Facts.decode(Facts.intern(raw, s), s) == Facts.decode(raw)
  end

  test "format: :interned yields what interning the raw extraction yields", %{symbols: s} do
    {:ok, raw} = Pipeline.extract([:lists])
    {:ok, interned} = Pipeline.extract([:lists], format: :interned, symbols: s)

    assert Facts.materialize(interned, s) == raw
  end

  test "format: :interned without a table is an argument error" do
    assert_raise ArgumentError, ~r/symbols:/, fn ->
      Pipeline.extract([:lists], format: :interned)
    end
  end

  test "relations outside the schema intern every field as a symbol", %{symbols: s} do
    raw = %{call_edge: [["A:f/1", "B:g/2"]], function_def: [["A:f/1", "A", "f", "1", "1"]]}
    interned = Facts.intern(raw, s)

    assert [{_, _}] = interned.call_edge
    assert [{_, _, _, 1, 1}] = interned.function_def
    assert Facts.materialize(interned, s) == raw
    assert Facts.decode(interned, s).call_edge == [["A:f/1", "B:g/2"]]
  end

  test "a row of the wrong width raises on intern", %{symbols: s} do
    assert_raise ArgumentError, ~r/expects 5 fields/, fn ->
      Facts.intern(%{function_def: [["A:f/1", "A"]]}, s)
    end
  end

  test "materialize/2 reads each id from the store once per pass" do
    state = CountingStore.new()
    s = Symbols.new(CountingStore, state)

    raw = %{
      call_edge: [["A:f/1", "B:g/2"], ["A:f/1", "B:h/0"], ["B:g/2", "A:f/1"]],
      function_def: [["A:f/1", "A", "f", "1", "1"], ["B:g/2", "B", "g", "2", "0"]]
    }

    assert Facts.materialize(Facts.intern(raw, s), s) == raw

    counts = :ets.tab2list(state.counts)
    assert counts != []
    assert Enum.all?(counts, fn {_id, n} -> n == 1 end), inspect(counts)
  end

  # Schema relations with their field kinds, and relations outside the
  # schema (every field a symbol, any width).
  defp raw_facts do
    known =
      Enum.map(Enum.take(Schema.all(), 40), fn %{name: name, fields: fields} ->
        row = fixed_list(Enum.map(fields, fn {_name, kind, _doc} -> cell(kind) end))
        StreamData.tuple({constant(name), list_of(row, max_length: 6)})
      end)

    unknown =
      StreamData.tuple(
        {member_of([:not_a_relation, :also_unknown]), list_of(list_of(symbol()), max_length: 6)}
      )

    map(list_of(one_of([unknown | known]), max_length: 8), &Map.new/1)
  end

  defp cell(kind) when kind in [:number, :label], do: map(integer(0..5_000), &Integer.to_string/1)
  defp cell(_kind), do: symbol()

  # A small alphabet so ids repeat across rows and relations.
  defp symbol, do: member_of(["A:f/1", "B:g/2", "A", "f", "", "Elixir.X:h/0:3", "é"])

  property "materialize(intern(raw)) is raw, row for row" do
    check all(raw <- raw_facts()) do
      s = Symbols.new()
      assert Facts.materialize(Facts.intern(raw, s), s) == raw
      Symbols.destroy(s)
    end
  end
end
