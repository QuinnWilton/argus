defmodule Argus.Graph.TraceGoneTest do
  @moduledoc """
  A module's trace removed between the lookup that read it and the mark
  that says it is used (`Roux.Blob.Trace.mark_used/1`) is a miss: a
  collection may be taking the segments its variants name, so the
  module is extracted again rather than served a pack whose blobs can
  vanish under it.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Graph
  alias Roux.Blob

  @moduletag :tmp_dir

  @module Argus.Test.Fixtures.LeakedTaskModule

  defp path, do: @module |> :code.which() |> List.to_string()

  # The module's facts over the store at `root`, and whether it was
  # extracted. `during_lookup` runs once, inside the lookup: after the
  # trace is read, while its variants are checked (their schema reads).
  defp facts(root, store_opts, during_lookup \\ fn -> :ok end) do
    db = Graph.new_db(%{@module => path()}, store: Blob.open!(root, store_opts))
    handler = "trace-gone-#{System.unique_integer([:positive])}"

    config = %{
      test: self(),
      database: Roux.Database.id(db),
      once: make_ref(),
      during_lookup: during_lookup
    }

    :ok =
      :telemetry.attach_many(
        handler,
        [[:argus, :graph, :pack], [:roux, :query, :start]],
        &__MODULE__.handle/4,
        config
      )

    try do
      {:ok, facts} = Argus.Graph.Extraction.module_facts(db, Path.expand(path()))
      {facts, extracted?()}
    after
      :telemetry.detach(handler)
      Roux.Database.shutdown(db)
    end
  end

  @doc false
  def handle([:argus, :graph, :pack], _measurements, %{module: @module}, config),
    do: send(config.test, :extracted)

  def handle([:roux, :query, :start], _, %{query_name: :schema_entry} = meta, config) do
    if meta.database == config.database and Process.put(config.once, true) == nil,
      do: config.during_lookup.()
  end

  def handle(_event, _measurements, _meta, _config), do: :ok

  defp extracted? do
    receive do
      :extracted -> true
    after
      0 -> false
    end
  end

  test "a trace removed while its lookup ran extracts the module again", %{tmp_dir: tmp} do
    root = Path.join(tmp, "store")
    {cold, true} = facts(root, [])

    # Found again, and marked used on every lookup (`refresh: 0`).
    assert {^cold, false} = facts(root, refresh: 0)

    # A collection removes every trace after this lookup read the module's.
    remove_traces = fn -> File.rm_rf!(Path.join(root, "traces")) end
    assert {^cold, true} = facts(root, [refresh: 0], remove_traces)
  end
end
