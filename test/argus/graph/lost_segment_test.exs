defmodule Argus.Graph.LostSegmentTest do
  @moduledoc """
  A segment the store lost while a module's trace still names it (swept
  by a collection that raced a run, or removed by hand) is a miss: the
  module is extracted again, the blobs it names are put back, and the
  run goes on. Reading the module's chunks raised
  `Roux.Blob.MissingError` instead, on every run that assembled a
  relation from them, until the store was cleared.
  """

  use ExUnit.Case, async: true

  alias Argus.Graph.Relations
  alias Argus.Test.Graph
  alias Roux.Blob

  @moduletag :souffle
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @modules [Argus.Test.Fixtures.LeakedTaskModule, Argus.Test.Fixtures.GenServerTaskConsumer]
  # The module with mailbox's findings: its lines are read to place them.
  @lost Argus.Test.Fixtures.LeakedTaskModule

  setup %{tmp_dir: tmp} do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")

    # A store of its own, where a first run extracted the modules and
    # kept each one's trace; then the base segment of one is gone.
    store = Path.join(tmp, "store")
    assert {:ok, _} = Argus.analyze(@modules, :mailbox, store: store)
    segment = base_segment(store, @lost)
    File.rm!(Blob.path(Blob.open!(store), segment))
    refute Blob.member?(Blob.open!(store), segment)

    %{store: store, segment: segment}
  end

  defp path(module), do: module |> :code.which() |> List.to_string()

  # The base segment of `module`'s pack, as its kept trace names it.
  defp base_segment(store, module) do
    db = Graph.new_db(%{module => path(module)}, store: Blob.open!(store))

    try do
      {:ok, %{pack: pack}} = Argus.Graph.Extraction.module_facts(db, path(module))
      {:ok, index} = Blob.get_term(db.blob, pack)
      [segment] = for {:base, segment, _relations} <- index, do: segment
      segment
    after
      Roux.Database.shutdown(db)
    end
  end

  # What `fun` returns, and the modules extracted while it ran.
  defp extracting(fun) do
    handler = "lost-segment-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, [:argus, :graph, :pack], &__MODULE__.forward/4, self())

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def forward(_event, _measurements, meta, test), do: send(test, {:extracted, meta.module})

  defp collect(acc) do
    receive do
      {:extracted, module} -> collect([module | acc])
    after
      0 -> acc |> Enum.uniq() |> Enum.sort()
    end
  end

  defp functions!(store) do
    db = Graph.new_db(Map.new(@modules, &{&1, path(&1)}), store: Blob.open!(store))

    try do
      digest = Relations.relation(db, {:test, :function_def})

      # A different producer selection bypasses the first solve's assembled
      # file, so this read must open the module's missing base segment.
      {:ok, %{function_def: file}} =
        Relations.files(db, :test, [{:function_def, digest}], [:base])

      {:ok, content} = Blob.get(db.blob, file)
      assert content != ""
      content
    after
      Roux.Database.shutdown(db)
    end
  end

  test "a relation assembled again extracts the module again, and puts its segment back",
       %{store: store, segment: segment, tmp_dir: tmp} do
    {functions, extracted} = extracting(fn -> functions!(store) end)

    # Every event is VM-wide: other tests extract beside this one.
    assert @lost in extracted
    assert Blob.member?(Blob.open!(store), segment)

    # The same rows a store that never lost anything gives.
    assert functions == functions!(Path.join(tmp, "fresh"))
  end

  test "a line table read again extracts the module again", %{store: store, tmp_dir: tmp} do
    # The solve is kept: only placing the findings reads the segments.
    {placed, extracted} = extracting(fn -> places(store) end)

    assert @lost in extracted
    assert placed != []
    assert placed == places(Path.join(tmp, "fresh"))
  end

  # Mailbox's findings over the modules, placed: each one's file and line.
  defp places(store) do
    db = Graph.new_db(Map.new(@modules, &{&1, path(&1)}), store: Blob.open!(store))

    try do
      %{mailbox: {:ok, located}} = Argus.Graph.located(db, :test, [:mailbox])
      located |> Enum.map(&{Path.basename(&1.file), &1.line}) |> Enum.sort()
    after
      Roux.Database.shutdown(db)
    end
  end
end
