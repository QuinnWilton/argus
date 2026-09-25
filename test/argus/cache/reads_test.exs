defmodule Argus.Cache.ReadsTest do
  use ExUnit.Case, async: true

  alias Argus.Cache.Reads

  test "a read outside any tracking records nothing and returns the value" do
    assert Reads.record("names", :value) == :value
    assert {:ok, []} == {:ok, elem(Reads.track(fn -> :done end), 1)}
  end

  test "reads are sorted and deduplicated, and a nested set adds to the one around it" do
    {result, outer} =
      Reads.track(fn ->
        Reads.record("names", 1)

        {:inner, inner} =
          Reads.track(fn ->
            Reads.record("version", 2)
            Reads.record("all", 3)
            Reads.record("version", 2)
            :inner
          end)

        assert inner == ["all", "version"]
        :outer
      end)

    assert result == :outer
    assert outer == ["all", "names", "version"]
  end

  test "a raise inside keeps its reads for the set around it, and goes on" do
    {_, outer} =
      Reads.track(fn ->
        try do
          Reads.track(fn ->
            Reads.record("layer_1", [])
            raise "boom"
          end)
        rescue
          RuntimeError -> :rescued
        end
      end)

    assert outer == ["layer_1"]
    assert_raise RuntimeError, fn -> Reads.track(fn -> raise "boom" end) end
    assert Reads.record("names", :value) == :value
    assert elem(Reads.track(fn -> :ok end), 1) == []
  end

  test "a read's digest is of what it names now" do
    assert Reads.digest("columns bif_call") ==
             Reads.value_digest(Argus.Schema.columns(:bif_call))

    refute Reads.digest("columns bif_call") == Reads.digest("columns remote_call")
  end
end
