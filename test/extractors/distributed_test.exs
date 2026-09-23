defmodule Argus.Extractors.ApiCalls.DistributedTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ApiCalls

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  # One module of every timeout shape, compiled once.
  setup_all do
    [{_mod, bin}] =
      Code.compile_string("""
      defmodule Argus.DistributedTest.Timeouts do
        def erpc4(n, a), do: :erpc.call(n, M, :f, a)
        def erpc5(n, a), do: :erpc.call(n, M, :f, a, 7000)
        def erpc2(n, f), do: :erpc.call(n, f)
        def erpc3(n, f), do: :erpc.call(n, f, 3000)
        def emulti4(ns, a), do: :erpc.multicall(ns, M, :f, a)
        def emulti3(ns, f), do: :erpc.multicall(ns, f, 2000)
        def rmulti_nodes(ns, a), do: :rpc.multicall(ns, M, :f, a)
        def rmulti_timeout(a), do: :rpc.multicall(M, :f, a, 4000)
        def multi3(ns), do: GenServer.multi_call(ns, Srv, :ping)
        def multi4(ns), do: GenServer.multi_call(ns, Srv, :ping, 900)
        def dirty(s), do: :gen_statem.call(s, :ping, {:dirty_timeout, 800})
      end
      """)

    {:ok, data} = Argus.Pipeline.Disassemble.disassemble_path(bin)
    facts = ApiCalls.extract(data)
    short = fn func -> func |> String.split(":") |> List.last() end

    %{
      rpc: Map.new(facts[:rpc_call], fn [_id, func, v, t] -> {short.(func), {v, t}} end),
      sync:
        Map.new(facts[:sync_call_timeout], fn [func, callee, t] ->
          {short.(func), {callee, t}}
        end)
    }
  end

  describe "extract/1 — RPC calls" do
    test "detects :rpc.call/4 with infinity timeout" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.RpcCaller))

      assert Map.has_key?(facts, :rpc_call)
      rows = facts[:rpc_call]

      assert Enum.any?(rows, fn [_, func, variant, timeout] ->
               String.contains?(func, "call_no_timeout") and
                 variant == "rpc" and timeout == "-1"
             end)
    end

    test "detects :rpc.call/5 with explicit timeout" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.RpcCaller))

      rows = facts[:rpc_call]

      assert Enum.any?(rows, fn [_, func, variant, timeout] ->
               String.contains?(func, "call_with_timeout") and
                 variant == "rpc" and timeout == "5000"
             end)
    end

    test "detects :rpc.multicall" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.RpcCaller))

      rows = facts[:rpc_call]

      assert Enum.any?(rows, fn [_, _, variant, _] ->
               variant == "multicall"
             end)
    end
  end

  describe "extract/1 — timeouts at the signatures' positions" do
    test "erpc waits forever unless it names a timeout", %{rpc: rpc} do
      assert rpc["erpc4/2"] == {"erpc", "-1"}
      assert rpc["erpc5/2"] == {"erpc", "7000"}
      assert rpc["erpc2/2"] == {"erpc", "-1"}
      assert rpc["erpc3/2"] == {"erpc", "3000"}
      assert rpc["emulti4/2"] == {"erpc_multicall", "-1"}
      assert rpc["emulti3/2"] == {"erpc_multicall", "2000"}
    end

    test "rpc:multicall/4 is told apart by its last argument", %{rpc: rpc} do
      assert rpc["rmulti_nodes/2"] == {"multicall", "-1"}
      assert rpc["rmulti_timeout/1"] == {"multicall", "4000"}
    end

    test "multi_call names its server second and its timeout fourth", %{sync: sync} do
      assert sync["multi3/1"] == {"Srv", "-1"}
      assert sync["multi4/1"] == {"Srv", "900"}
    end

    test "a gen_statem dirty timeout is its timeout", %{sync: sync} do
      assert {_, "800"} = sync["dirty/1"]
    end
  end

  describe "extract/1 — :global synchronization" do
    test "records :global.set_lock/2 with infinity retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))

      assert Map.has_key?(facts, :global_op)
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, op, retries] ->
               String.contains?(func, "lock_default") and
                 op == "set_lock" and retries == "infinity"
             end)
    end

    test "records :global.set_lock/3 with retries=0 as non-blocking" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, op, retries] ->
               String.contains?(func, "try_lock_once") and
                 op == "set_lock" and retries == "0"
             end)
    end

    test "records :global.set_lock/3 with explicit infinity retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, _op, retries] ->
               String.contains?(func, "lock_infinity") and retries == "infinity"
             end)
    end

    test "records :global.set_lock/3 with positive integer retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, _op, retries] ->
               String.contains?(func, "lock_with_retries") and retries == "5"
             end)
    end

    test "records :global.trans/2 as blocking with infinity retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, op, retries] ->
               String.contains?(func, "trans_default") and
                 op == "trans" and retries == "infinity"
             end)
    end

    test "records :global.del_lock as non-blocking" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, _func, op, retries] ->
               op == "del_lock" and retries == "0"
             end)
    end
  end

  describe "extract/1 — global registration" do
    test "detects :global.register_name" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalRegisterModule))

      assert Map.has_key?(facts, :global_register)
      rows = facts[:global_register]
      assert rows != []
    end
  end

  describe "extract/1 — node operations" do
    test "detects Node.connect" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.NodeOperationsModule))

      assert Map.has_key?(facts, :node_operation)
      rows = facts[:node_operation]
      ops = Enum.map(rows, fn [_, _, op] -> op end)
      assert "connect" in ops
    end

    test "detects Node.disconnect" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.NodeOperationsModule))

      rows = facts[:node_operation]
      ops = Enum.map(rows, fn [_, _, op] -> op end)
      assert "disconnect" in ops
    end

    test "detects Node.ping" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.NodeOperationsModule))

      rows = facts[:node_operation]
      ops = Enum.map(rows, fn [_, _, op] -> op end)
      assert "ping" in ops
    end
  end

  describe "extract/1 — distributed stores" do
    test "detects :mnesia operations" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.MnesiaModule))

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
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.RpcCaller],
                 extractors: [ApiCalls]
               )

      assert Map.has_key?(facts, :rpc_call)
    end
  end
end
