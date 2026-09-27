defmodule Argus.Schema.ReadsTest do
  use ExUnit.Case, async: true

  alias Argus.Graph
  alias Argus.Schema.Reads

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

  test "an isolated set leaves the one around it as it was" do
    {:outer, outer} =
      Reads.track(fn ->
        Reads.record("names", 1)
        {:inner, ["version"]} = Reads.isolated(fn -> Reads.record("version", :inner) end)
        :outer
      end)

    assert outer == ["names"]
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
    value = :erlang.term_to_binary(Argus.Schema.columns(:bif_call), [:deterministic])

    assert Graph.Reads.entry_digest("columns bif_call") ==
             :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

    refute Graph.Reads.entry_digest("columns bif_call") ==
             Graph.Reads.entry_digest("columns remote_call")
  end
end
