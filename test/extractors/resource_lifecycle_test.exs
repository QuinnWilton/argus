defmodule Argus.Extractors.ResourceLifecycleTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ResourceLifecycle

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — file operations" do
    test "detects File.open as resource_open" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.FileOpener))

      assert Map.has_key?(facts, :resource_open)
      rows = facts[:resource_open]
      types = Enum.map(rows, fn [_, _, type] -> type end)
      assert "file" in types
    end

    test "detects File.close as resource_close" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.FileOpener))

      assert Map.has_key?(facts, :resource_close)
      rows = facts[:resource_close]
      types = Enum.map(rows, fn [_, _, type] -> type end)
      assert "file" in types
    end
  end

  describe "extract/1 — socket operations" do
    test "detects :gen_tcp.connect as resource_open" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.SocketModule))

      assert Map.has_key?(facts, :resource_open)
      rows = facts[:resource_open]
      types = Enum.map(rows, fn [_, _, type] -> type end)
      assert "socket" in types
    end

    test "detects :gen_tcp.close as resource_close" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.SocketModule))

      assert Map.has_key?(facts, :resource_close)
      rows = facts[:resource_close]
      types = Enum.map(rows, fn [_, _, type] -> type end)
      assert "socket" in types
    end

    test "detects :gen_tcp.listen as resource_open" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.SocketModule))

      rows = facts[:resource_open]

      assert Enum.any?(rows, fn [_, func, type] ->
               String.contains?(func, "listen") and type == "socket"
             end)
    end
  end

  describe "extract/1 — port operations" do
    test "detects Port.open as resource_open" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.PortModule))

      assert Map.has_key?(facts, :resource_open)
      rows = facts[:resource_open]
      types = Enum.map(rows, fn [_, _, type] -> type end)
      assert "port" in types
    end

    test "detects Port.close as resource_close" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.PortModule))

      assert Map.has_key?(facts, :resource_close)
      rows = facts[:resource_close]
      types = Enum.map(rows, fn [_, _, type] -> type end)
      assert "port" in types
    end

    test "detects :erlang.open_port as port_open" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.PortModule))

      assert Map.has_key?(facts, :port_open)
      rows = facts[:port_open]
      assert length(rows) >= 1
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = ResourceLifecycle.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Extract.extract/2" do
      assert {:ok, facts} =
               Argus.Extract.extract(
                 [Argus.Test.Fixtures.FileOpener],
                 extractors: [ResourceLifecycle]
               )

      assert Map.has_key?(facts, :resource_open)
    end
  end
end
