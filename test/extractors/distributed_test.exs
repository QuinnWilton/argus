defmodule Argus.Extractors.DistributedTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.Distributed

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — RPC calls" do
    test "detects :rpc.call/4 with infinity timeout" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.RpcCaller))

      assert Map.has_key?(facts, :rpc_call)
      rows = facts[:rpc_call]

      assert Enum.any?(rows, fn [_, func, variant, timeout] ->
               String.contains?(func, "call_no_timeout") and
                 variant == "rpc" and timeout == "infinity"
             end)
    end

    test "detects :rpc.call/5 with explicit timeout" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.RpcCaller))

      rows = facts[:rpc_call]

      assert Enum.any?(rows, fn [_, func, variant, timeout] ->
               String.contains?(func, "call_with_timeout") and
                 variant == "rpc" and timeout == "5000"
             end)
    end

    test "detects :rpc.multicall" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.RpcCaller))

      rows = facts[:rpc_call]

      assert Enum.any?(rows, fn [_, _, variant, _] ->
               variant == "multicall"
             end)
    end
  end

  describe "extract/1 — global registration" do
    test "detects :global.register_name" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.GlobalRegisterModule))

      assert Map.has_key?(facts, :global_register)
      rows = facts[:global_register]
      assert length(rows) >= 1
    end
  end

  describe "extract/1 — node operations" do
    test "detects Node.connect" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.NodeOperationsModule))

      assert Map.has_key?(facts, :node_operation)
      rows = facts[:node_operation]
      ops = Enum.map(rows, fn [_, _, op] -> op end)
      assert "connect" in ops
    end

    test "detects Node.disconnect" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.NodeOperationsModule))

      rows = facts[:node_operation]
      ops = Enum.map(rows, fn [_, _, op] -> op end)
      assert "disconnect" in ops
    end

    test "detects Node.ping" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.NodeOperationsModule))

      rows = facts[:node_operation]
      ops = Enum.map(rows, fn [_, _, op] -> op end)
      assert "ping" in ops
    end
  end

  describe "extract/1 — distributed stores" do
    test "detects :mnesia operations" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.MnesiaModule))

      assert Map.has_key?(facts, :distributed_store_op)
      rows = facts[:distributed_store_op]

      stores = Enum.map(rows, fn [_, _, store, _] -> store end)
      assert "mnesia" in stores

      ops = Enum.map(rows, fn [_, _, _, op] -> op end)
      assert "transaction" in ops
      assert "read" in ops
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = Distributed.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.RpcCaller],
                 extractors: [Distributed]
               )

      assert Map.has_key?(facts, :rpc_call)
    end
  end
end
