defmodule Argus.RunTest do
  use ExUnit.Case, async: true

  doctest Argus.Run

  test "an unknown backend is an argument error naming it" do
    assert_raise ArgumentError, ~r/:nope/, fn -> Argus.Run.backend(backend: :nope) end
  end

  test "an option only the batch backend reads picks it, unless a backend is named" do
    for option <- [:facts_dir, :cache, :solve_cache, :extractors, :relations] do
      assert {:batch, _} = Argus.Run.backend([{option, :x}])
      assert {:graph, [{^option, :x}]} = Argus.Run.backend([{option, :x}, backend: :graph])
    end
  end
end

defmodule Argus.RunFactsTest do
  @moduledoc """
  `Argus.Analysis.extract_facts/3` writes the same directory on both
  backends: the same files, each holding the same rows (a relation is a
  set: the backends write rows in orders of their own), `line_info`
  among them, and the imprecision trace only for `:coverage`.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.PidFlow

  @modules [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow, :gen_server] ++
             for(
               name <- ~w(SafeCall UserA UserB TargetA TargetB),
               do: Module.concat(PidFlow, name)
             )

  defp rows(dir) do
    for name <- File.ls!(dir), String.ends_with?(name, ".facts"), into: %{} do
      rows = dir |> Path.join(name) |> File.read!() |> String.split("\n", trim: true)
      {name, Enum.sort(rows)}
    end
  end

  defp extracted(analyses, backend) do
    {:ok, dir} = Argus.Analysis.extract_facts(@modules, analyses, backend: backend)

    try do
      rows(dir)
    after
      File.rm_rf!(Path.dirname(dir))
    end
  end

  for analyses <- [[:startup, :races], [:coverage], [:mailbox, :ets, :effects]] do
    test "for #{inspect(analyses)}, the same rows in every file on both backends" do
      unless Argus.Souffle.available?(), do: flunk("souffle not installed")

      batch = extracted(unquote(analyses), :batch)
      graph = extracted(unquote(analyses), :graph)

      assert Map.keys(graph) == Map.keys(batch)
      assert graph["line_info.facts"] != []
      assert graph["imprecision.facts"] != [] == :coverage in unquote(analyses)

      differing = for {file, rows} <- batch, graph[file] != rows, do: file
      assert differing == []
    end
  end
end
