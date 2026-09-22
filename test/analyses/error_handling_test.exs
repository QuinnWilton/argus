defmodule Argus.Analyses.ErrorHandlingTest do
  use ExUnit.Case

  alias Argus.Souffle

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :error_handling)
    results
  end

  describe "handle_info_partial" do
    test "a partial handle_info with a late-message source is a note, GenStage included" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.PartialInfoServer,
          Argus.Test.Fixtures.TotalInfoServer,
          Argus.Test.Fixtures.PartialInfoStage,
          Argus.Test.Fixtures.QuietPartialInfoServer,
          Argus.Test.Fixtures.AppliesPartialInfoServer,
          Argus.Test.Fixtures.SelfSendPartialInfoServer,
          Argus.Test.Fixtures.MonitorsWithoutCatchall
        ])

      partial = Enum.map(results["handle_info_partial"], fn [mod, _f] -> mod end) |> Enum.sort()

      assert partial == [
               "Argus.Test.Fixtures.AppliesPartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoStage",
               "Argus.Test.Fixtures.SelfSendPartialInfoServer"
             ]

      # The monitoring module keeps its warning-grade finding, not this one.
      assert Enum.map(results["handle_info_without_catchall"], fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end
  end

  describe "handle_info_without_catchall" do
    test "a monitoring GenServer with only a :DOWN clause is reported" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.MonitorsWithoutCatchall,
          Argus.Test.Fixtures.MonitorsWithCatchall
        ])

      mods = Enum.map(results["handle_info_without_catchall"], fn [mod, _f] -> mod end)

      assert mods == ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end

    test "a missing :EXIT clause is reported once, as the specific finding" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.TrapsWithoutExitClause])

      assert results["handle_info_without_catchall"] == []
    end
  end
end
