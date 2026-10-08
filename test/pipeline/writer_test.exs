defmodule Argus.Pipeline.WriterTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline.Writer

  @moduletag :tmp_dir

  defp contents(dir) do
    for file <- dir |> File.ls!() |> Enum.sort(),
        into: %{},
        do: {file, File.read!(Path.join(dir, file))}
  end

  defp write(dir, modules, fun) do
    File.mkdir_p!(dir)

    {:ok, writer} =
      Enum.reduce(modules, {:ok, Writer.new(dir, MapSet.new([:jump, :call_edge]))}, fn facts,
                                                                                       {:ok, w} ->
        fun.(w, facts)
      end)

    Writer.close(writer)
    contents(dir)
  end

  test "facts encoded in the worker are written oldest row first, and only the written relations",
       %{tmp_dir: tmp} do
    # Rows arrive newest first, as the pipeline merges them; a relation
    # outside the written set, and an empty one, get no file.
    modules = [
      %{jump: [["M:f/1#2", "3"], ["M:f/1#0", "1"]], call_edge: [], label_at: [["M:f/1#0", "1"]]},
      %{jump: [["N:g/0#1", "7"]], call_edge: [["N:g/0", "a\tb"]]}
    ]

    written = MapSet.new([:jump, :call_edge])

    encoded =
      write(Path.join(tmp, "encoded"), modules, fn w, facts ->
        Writer.append_encoded(w, Writer.encode(facts, written))
      end)

    assert encoded["jump.facts"] == "M:f/1#0\t1\nM:f/1#2\t3\nN:g/0#1\t7\n"
    assert encoded["call_edge.facts"] == "N:g/0\ta\\tb\n"
    refute Map.has_key?(encoded, "label_at.facts")
  end

  test "relations: names the relations written, or those left out" do
    facts = %{jump: [["M:f/1#0", "1"]], label_at: [["M:f/1#0", "1"]], custom: [["x"]]}

    assert facts |> Writer.encode(Writer.written(:all)) |> Map.keys() |> Enum.sort() ==
             [:custom, :jump, :label_at]

    assert facts |> Writer.encode(Writer.written([:jump])) |> Map.keys() == [:jump]

    assert facts |> Writer.encode(Writer.written({:except, [:jump]})) |> Map.keys() |> Enum.sort() ==
             [:custom, :label_at]
  end
end
