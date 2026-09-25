defmodule Argus.Analyses.ToolingTest do
  @moduledoc """
  A finding in code only developers' tools or tests run steps down a
  level, and nothing else moves (clientlib/tooling.dl,
  `Argus.Findings.Tooling`): three modules make the same call, and only
  the one the structure names as tooling reports it lower.
  """

  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.Tooling.{DevSetup, Product}

  @mods [Mix.ArgusFixtures.Seed, Product, DevSetup]

  defp skip_without_souffle do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
  end

  # Code execution each module's export reaches, by module.
  defp findings(opts) do
    opts =
      opts
      |> Keyword.put(:analyses, [:unsafe_input])
      |> Keyword.put(:cache, Argus.Test.Memo.store())

    assert {:ok, %Argus.Findings{degraded: []} = r} = Argus.Findings.run(@mods, opts)

    r.findings
    |> Enum.filter(&(&1.title =~ "Dynamic code execution"))
    |> Map.new(&{&1.module, &1})
  end

  test "a module under Mix. steps down, structurally; the product and the undecided do not" do
    skip_without_souffle()
    by_module = findings([])

    assert %{severity: :warning, provenance: :structural, confidence: nil} =
             seed =
             by_module[Mix.ArgusFixtures.Seed]

    assert List.last(seed.help) =~ "tooling: a Mix task"

    # The positive twins: the same call, at its structural severity.
    for mod <- [Product, DevSetup] do
      assert %{severity: :error, provenance: :structural} = by_module[mod]
      refute Enum.any?(by_module[mod].help, &(&1 =~ "tooling"))
    end
  end

  describe "the tooling rows" do
    defp tooling_rows(facts) do
      assert {:ok, results} = Argus.Test.Memo.run_rules(facts, :structure)
      Enum.sort(results["tooling"] || [])
    end

    @base %{
      function_def: [
        ["Mix.Tasks.Seed:run/1", "Mix.Tasks.Seed", "run", "1", "1"],
        ["App.DevSetup:run/0", "App.DevSetup", "run", "0", "1"],
        ["App.Worker:run/0", "App.Worker", "run", "0", "1"]
      ],
      tooling_module: [["Mix.Tasks.Seed", "mix"]]
    }

    test "a structural row is the structure's at 1000, and nothing else" do
      skip_without_souffle()
      assert tooling_rows(@base) == [["Mix.Tasks.Seed", "mix", "1000"]]
    end
  end
end
