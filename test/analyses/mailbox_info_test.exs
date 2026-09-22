defmodule Argus.Analyses.MailboxInfoTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Rows

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp analyze(modules) do
    assert {:ok, results} = Argus.analyze(modules, :mailbox)
    results
  end

  defp partial(results, source),
    do:
      Rows.where(results, :mailbox, "partial_handler",
        source: source,
        drop: [:source, :missing, :detail]
      )

  describe "partial_handler: late_message" do
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

      partial = Enum.map(partial(results, "late_message"), fn [mod, _f] -> mod end) |> Enum.sort()

      assert partial == [
               "Argus.Test.Fixtures.AppliesPartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoServer",
               "Argus.Test.Fixtures.PartialInfoStage",
               "Argus.Test.Fixtures.SelfSendPartialInfoServer"
             ]

      # The monitoring module keeps its warning-grade finding, not this one.
      assert Enum.map(partial(results, "runtime"), fn [mod, _f] -> mod end) ==
               ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end
  end

  describe "partial_handler: runtime" do
    test "a monitoring GenServer with only a :DOWN clause is reported" do
      skip_without_souffle()

      results =
        analyze([
          Argus.Test.Fixtures.MonitorsWithoutCatchall,
          Argus.Test.Fixtures.MonitorsWithCatchall
        ])

      mods = Enum.map(partial(results, "runtime"), fn [mod, _f] -> mod end)

      assert mods == ["Argus.Test.Fixtures.MonitorsWithoutCatchall"]
    end

    test "a missing :EXIT clause is reported once, as the specific finding" do
      skip_without_souffle()

      results = analyze([Argus.Test.Fixtures.TrapsWithoutExitClause])

      assert partial(results, "runtime") == []
    end
  end
end
