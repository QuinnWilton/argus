defmodule Argus.Graph.StoreRaceTest do
  @moduledoc """
  Analyses running side by side over one fresh blob store lose no
  inputs. Every solve links the store's entries for its inputs, the
  empty one above all (every relation a program has no rows for), while
  others put the same entries: a store that replaced an entry already
  there (a rename onto it) hid it from a concurrent link on APFS, and
  solves failed with `{:input_failed, file, :enoent}` at random.

  A small program reads every serialized schema relation, exercising
  the concurrent publication and linking without compiling five whole
  analyses per fixture set. The analysis rules have their own tests.
  Not async: the eight concurrent runs have the machine to themselves
  after the async tests, rather than competing with them for disk I/O.
  """

  use ExUnit.Case, async: false
  @moduletag :souffle

  @moduletag :cache
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  test "concurrent runs over a fresh store degrade nothing", %{tmp_dir: dir} do
    fixtures =
      for module <- Application.spec(:argus_beam, :modules),
          String.starts_with?(Atom.to_string(module), "Elixir.Argus.Test.Fixtures."),
          do: module

    sets = fixtures |> Enum.sort() |> Enum.chunk_every(4) |> Enum.take(16)
    store = Path.join(dir, "store")
    rules = rules!(dir)
    priors = Enum.map(Argus.Priors.questions(), &Atom.to_string(&1.relation()))

    rounds =
      for _round <- 1..2 do
        sets
        |> Task.async_stream(
          &Argus.analyze(&1, {:custom, rules}, store: store),
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} ->
          assert {:ok, %{"nonempty" => rows}} = result
          assert ["function_def"] in rows
          refute Enum.any?(rows, fn [relation] -> relation in priors end)
          Enum.sort(rows)
        end)
      end

    assert [cold, warm] = rounds
    assert warm == cold
  end

  defp rules!(dir) do
    path = Path.join(dir, "store_race.dl")
    in_process = Argus.Schema.in_process_only()

    rules =
      for relation <- Argus.Schema.all(), relation.name not in in_process do
        args = Enum.map_join(relation.fields, ", ", fn _field -> "_" end)
        "nonempty(\"#{relation.name}\") :- #{relation.name}(#{args})."
      end

    File.write!(path, """
    .include "#{Argus.Dl.path("base.dl")}"
    .include "#{Argus.Dl.path("layer2.dl")}"
    .include "#{Argus.Dl.path("priors.dl")}"
    .decl nonempty(relation: symbol)
    .output nonempty
    #{Enum.join(rules, "\n")}
    """)

    path
  end
end
