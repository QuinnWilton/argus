defmodule Argus.Extractors.SocketsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Sockets
  alias Argus.Test.Fixtures.Sockets, as: F

  defp facts(module) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(module)))
    Sockets.extract(data)
  end

  # {function, transport, mode, param} per socket_active row.
  defp active(module) do
    rows =
      for [_id, func, t, mode, param] <- Map.get(facts(module), :socket_active, []),
          do: {name(func), t, mode, param}

    Enum.sort(rows)
  end

  defp name(func_id), do: func_id |> String.split(":") |> List.last()

  describe "socket_active" do
    test "a connect's literal :active entry, and active: true where it leaves the entry out" do
      assert {"handle_continue/2", "tcp", "true", "-1"} in active(F.ActiveTcp)
      assert {"handle_continue/2", "tcp", "false", "-1"} in active(F.PassiveTcp)
      assert {"init/1", "tcp", "default", "-1"} in active(F.DefaultActive)
      assert {"init/1", "ssl", "once", "-1"} in active(F.TlsTakesTcpClose)
    end

    test "a setopts through :inet, :ssl, or a transport module in a variable" do
      assert {"handle_info/2", "inet", "once", "-1"} in active(F.InetTcp)
      assert {"handle_info/2", "ssl", "once", "-1"} in active(F.TlsTakesTcpClose)
      assert {"handle_info/2", "any", "once", "-1"} in active(F.ThroughTransport)
    end

    test "a wrapper's options are its parameter, and :ssl.connect/3's by what the call hands it" do
      assert active(F.Wrapped.Socket) == [
               {"create/4", "ssl", "param", "2"},
               {"create/4", "tcp", "param", "2"},
               {"setopts/2", "inet", "param", "1"},
               {"setopts/2", "ssl", "param", "1"}
             ]
    end
  end

  describe "socket_opts_arg" do
    test "the literal lists a caller hands on, with their :active entry" do
      rows =
        for [_id, caller, callee, pos, mode] <- facts(F.Wrapped.Client).socket_opts_arg,
            do: {name(caller), name(callee), pos, mode}

      assert Enum.sort(rows) == [
               {"handle_call/3", "setopts/2", "1", "false"},
               {"handle_call/3", "setopts/2", "1", "true"},
               {"init/1", "create/4", "2", "false"}
             ]
    end
  end

  test "a module with no sockets has no rows" do
    assert facts(Argus.Test.Fixtures.PlainModule) == %{}
  end
end
