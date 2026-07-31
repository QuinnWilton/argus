defmodule Argus.Extractors.PortsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Ports

  setup do
    {:ok, data} =
      BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PortUser)))

    %{rows: Ports.extract(data) |> Map.get(:port_open, [])}
  end

  defp target(rows, mechanism) do
    Enum.find_value(rows, fn [_id, _func, mech, target] -> if mech == mechanism, do: target end)
  end

  test "recognizes every port-opening mechanism", %{rows: rows} do
    # `Port.open/2` compiles to `:erlang.open_port` in bytecode, so both the
    # `Port.open` and `:erlang.open_port` call sites surface as the latter.
    mechanisms = rows |> Enum.map(fn [_, _, mech, _] -> mech end) |> Enum.sort()

    assert mechanisms ==
             [
               "System.cmd",
               "System.shell",
               "erlang.open_port",
               "erlang.open_port",
               "erlang.open_port",
               "os.cmd"
             ]
  end

  test "resolves a static spawn target, and stays honest on a runtime one", %{rows: rows} do
    # spawn_cmd → {:spawn, "cat"}, erl_port → {:spawn, "true"}, spawn_exe →
    # a runtime path (dynamic).
    spawn_targets =
      rows
      |> Enum.filter(fn [_, _, mech, _] -> mech == "erlang.open_port" end)
      |> Enum.map(fn [_, _, _, target] -> target end)
      |> Enum.sort()

    assert spawn_targets == ["cat", "dynamic", "true"]
  end

  test "resolves the command of System.cmd / System.shell / os.cmd", %{rows: rows} do
    assert target(rows, "System.cmd") == "ls"
    assert target(rows, "System.shell") == "echo hi"
    assert target(rows, "os.cmd") == "date"
  end

  test "attributes each port to its owning function", %{rows: rows} do
    assert Enum.all?(rows, fn [_id, func, _, _] ->
             func =~ ~r/^Argus\.Test\.Fixtures\.PortUser:/
           end)
  end

  test "returns no rows for a module that opens no ports" do
    {:ok, data} =
      BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

    assert Ports.extract(data) == %{}
  end
end
