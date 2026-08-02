defmodule Argus.Analyses.UnboundedDynamicChildrenTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.UnboundedChildren, as: U

  @all [U.Worker, U.UncappedSup, U.CappedSup, U.PublicLive, U.CappedLive, U.Internal]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp findings do
    assert {:ok, r} = Argus.analyze(@all, :unbounded_dynamic_children)
    Map.get(r, "unbounded_children_from_request", [])
  end

  defp callers, do: findings() |> Enum.map(fn [_s, _c, via, _k] -> via end) |> Enum.sort()

  defp named?(list, f), do: Enum.any?(list, &String.contains?(&1, f))

  test "an uncapped supervisor driven by a request is reported" do
    skip_without_souffle()
    assert named?(callers(), "PublicLive")
  end

  test "a ceiling discharges it" do
    skip_without_souffle()
    refute named?(callers(), "CappedLive"), "max_children is the whole fix"
  end

  test "unbounded but internally driven is not reported" do
    skip_without_souffle()

    # Most dynamic supervisors are this. Reporting them would bury the ones
    # an outside party can drive, which is the only claim being made.
    refute named?(callers(), "Internal")
  end

  test "the finding names the entry surface it came from" do
    skip_without_souffle()

    assert [[sup, child, _via, kind]] =
             Enum.filter(findings(), fn [_s, _c, v, _k] -> v =~ "PublicLive" end)

    assert sup =~ "UncappedSup"
    assert child =~ "Worker"
    assert kind == "live_view"
  end
end
