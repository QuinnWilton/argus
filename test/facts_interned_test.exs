defmodule Argus.FactsInternedTest do
  use ExUnit.Case, async: true

  alias Argus.{Facts, Pipeline, Symbols}

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
end
