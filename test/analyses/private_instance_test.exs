defmodule Argus.Analyses.PrivateInstanceTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.PrivateConn, as: P
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  @modules [P.Conn, P.Pool, P.Cache, P.Reporter, P.Tree]

  setup do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  defp pairs(rows), do: rows |> Enum.map(fn [a, b | _] -> {short(a), short(b)} end) |> Enum.uniq()
  defp short(mod), do: mod |> String.split(".") |> List.last()

  test "a sibling's own connection is not the supervised one it couples to" do
    {:ok, r} = Memo.analyze(@modules, :coupling)

    coupled =
      r
      |> Rows.where(:coupling, "sibling_dependency", reason: "restart_isolation")
      |> Enum.map(fn [_sup, caller, callee | _] -> {short(caller), short(callee)} end)
      |> Enum.uniq()

    assert {"Reporter", "Cache"} in coupled
    refute {"Pool", "Conn"} in coupled
  end

  test "terminate/2 and a handler stopping a connection of its own touch no sibling" do
    {:ok, r} = Memo.analyze(@modules, :shutdown)
    touched = r |> Map.get("teardown_touches_sibling", []) |> pairs()

    assert {"Reporter", "Cache"} in touched
    refute {"Pool", "Conn"} in touched
  end
end
