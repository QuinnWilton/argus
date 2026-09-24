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

  test "facts encoded in the worker are written as appending them writes them", %{tmp_dir: tmp} do
    # Rows arrive newest first, as the pipeline merges them; a relation
    # outside the written set, and an empty one, get no file.
    modules = [
      %{jump: [["M:f/1#2", "3"], ["M:f/1#0", "1"]], call_edge: [], label_at: [["M:f/1#0", "1"]]},
      %{jump: [["N:g/0#1", "7"]], call_edge: [["N:g/0", "a\tb"]]}
    ]

    written = MapSet.new([:jump, :call_edge])

    appended = write(Path.join(tmp, "appended"), modules, &Writer.append/2)

    encoded =
      write(Path.join(tmp, "encoded"), modules, fn w, facts ->
        Writer.append_encoded(w, Writer.encode(facts, written))
      end)

    assert encoded == appended
    assert appended["jump.facts"] == "M:f/1#0\t1\nM:f/1#2\t3\nN:g/0#1\t7\n"
    assert appended["call_edge.facts"] == "N:g/0\ta\\tb\n"
    refute Map.has_key?(appended, "label_at.facts")
  end

  test "each file's digest is its bytes', hashed as they were written", %{tmp_dir: tmp} do
    written = MapSet.new([:jump, :call_edge])

    {:ok, writer} =
      [%{jump: [["M:f/1#0", "1"]]}, %{jump: [["N:g/0#1", "7"]], call_edge: [["N:g/0", "x"]]}]
      |> Enum.reduce({:ok, Writer.new(tmp, written)}, fn facts, {:ok, w} ->
        Writer.append_encoded(w, Writer.encode(facts, written))
      end)

    Writer.close(writer)

    expected =
      for file <- File.ls!(tmp), into: %{} do
        {file,
         :crypto.hash(:sha256, File.read!(Path.join(tmp, file))) |> Base.encode16(case: :lower)}
      end

    assert Writer.digests(writer) == expected
    assert Map.keys(expected) |> Enum.sort() == ["call_edge.facts", "jump.facts"]
  end
end
