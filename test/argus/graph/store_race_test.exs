defmodule Argus.Graph.StoreRaceTest do
  @moduledoc """
  Analyses running side by side over one fresh blob store degrade
  nothing. Every solve links the store's entries for its inputs, the
  empty one above all (every relation a program has no rows for), while
  others put the same entries: a store that replaced an entry already
  there (a rename onto it) hid it from a concurrent link on APFS, and
  solves failed with `{:input_failed, file, :enoent}` at random.

  Not async: its eight runs of five analyses start up to 32 solves at
  once, by design, and beside the suite on a four-core CI runner they
  held every core long enough for tests on ExUnit's default minute to
  run out of it. After the async tests, it has the machine to itself.
  """

  use ExUnit.Case, async: false

  @moduletag :cache
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @analyses [:mailbox, :ets, :startup, :races, :coupling]

  test "concurrent runs over a fresh store degrade nothing", %{tmp_dir: dir} do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")

    fixtures =
      for module <- Application.spec(:argus_beam, :modules),
          String.starts_with?(Atom.to_string(module), "Elixir.Argus.Test.Fixtures."),
          do: module

    sets = fixtures |> Enum.sort() |> Enum.chunk_every(4) |> Enum.take(16)
    store = Path.join(dir, "store")

    for _round <- 1..2 do
      degraded =
        sets
        |> Task.async_stream(
          &Argus.run_analyses(&1, analyses: @analyses, store: store),
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, {:ok, found}} -> found.degraded end)

      assert degraded == []
    end
  end
end
