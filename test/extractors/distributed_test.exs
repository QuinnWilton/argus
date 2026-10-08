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
        def block4(n), do: :rpc.block_call(n, Cache, :get, [])
        def block5(n), do: :rpc.block_call(n, Cache, :get, [], 900)
        def yield1(key), do: :rpc.yield(key)
        def nb_yield2(key), do: :rpc.nb_yield(key, :infinity)
        def recv1(req), do: :erpc.receive_response(req)
        def recv2(req), do: :erpc.receive_response(req, 600)
        def alive(n, pid), do: :rpc.call(n, Process, :alive?, [pid])
        def tab(n), do: :rpc.call(n, :ets, :tab2list, [:t])
        def mc3(), do: :rpc.multicall(:ets, :lookup, [:t, :k])
        def mc4t(), do: :rpc.multicall(:ets, :lookup, [:t, :k], 100)
        def mcnodes(ns), do: :rpc.multicall(ns, :ets, :lookup, [:t, :k])
        def remote(n, m, f, a, timeout \\\\ :infinity), do: :rpc.call(n, m, f, a, timeout)
        def apps(n), do: :rpc.call(n, :application, :which_applications, [])
        def apps_within(n, t), do: :rpc.call(n, :application, :which_applications, [t])
        def pair(n), do: :erpc.call(n, :ets, :lookup, [:t, :k])
        def mc3_none(), do: :rpc.multicall(:erlang, :node, [])
      end
      """)

    {:ok, data} = Argus.Pipeline.Disassemble.disassemble_path(bin)
    facts = ApiCalls.extract(data)
    short = fn func -> func |> String.split(":") |> List.last() end

    %{
      rpc: Map.new(facts[:rpc_call], fn [_id, func, v, t] -> {short.(func), {v, t}} end),
      target:
        Map.new(facts[:rpc_call], fn [id, func, _v, _t] ->
          [target] = for [^id, target] <- facts[:rpc_target], do: target
          {short.(func), target}
        end),
      arity:
        Map.new(facts[:rpc_arity], fn [id, n] ->
          [func] = for [^id, func, _, _] <- facts[:rpc_call], do: func
          {short.(func), n}
        end),
      timeout_param:
        Map.new(facts[:rpc_timeout_param], fn [id, pos] ->
          [func] = for [^id, func, _, _] <- facts[:rpc_call], do: func
          {short.(func), pos}
        end),
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

    test "block_call, yield and receive_response wait forever without a timeout", %{rpc: rpc} do
      assert rpc["block4/1"] == {"block_call", "-1"}
      assert rpc["block5/1"] == {"block_call", "900"}
      assert rpc["yield1/1"] == {"yield", "-1"}
      assert rpc["nb_yield2/1"] == {"nb_yield", "-1"}
      assert rpc["recv1/1"] == {"erpc_receive", "-1"}
      assert rpc["recv2/1"] == {"erpc_receive", "600"}
    end

    test "a timeout that is a parameter says which one", %{rpc: rpc, timeout_param: params} do
      assert rpc["remote/5"] == {"rpc", "0"}
      assert params == %{"remote/5" => "4"}
    end
  end

  describe "extract/1 — the remote function an rpc runs" do
    test "is read from the M and F arguments", %{target: target} do
      assert target["alive/2"] == "Process.alive?"
      assert target["tab/1"] == ":ets.tab2list"
      assert target["block4/1"] == "Cache.get"
      assert target["erpc4/2"] == "M.f"
    end

    test "multicall's M and F move with its nodes argument", %{target: target} do
      assert target["mc3/0"] == ":ets.lookup"
      assert target["mc4t/0"] == ":ets.lookup"
      assert target["mcnodes/1"] == ":ets.lookup"
      assert target["rmulti_nodes/2"] == "M.f"
    end

    test "a fun, a parameter, or an answer asked for elsewhere", %{target: target} do
      assert target["erpc2/2"] == "fun"
      assert target["emulti3/2"] == "fun"
      assert target["remote/5"] == "dynamic"
      assert target["yield1/1"] == "dynamic"
      assert target["recv1/1"] == "dynamic"
    end
  end

  describe "extract/1 — how many arguments the remote function gets" do
    test "is the length of a list known whole", %{arity: arity} do
      assert arity["apps/1"] == "0"
      assert arity["pair/1"] == "2"
      assert arity["tab/1"] == "1"
      assert arity["block4/1"] == "0"
      assert arity["mc3_none/0"] == "0"
      assert arity["mc4t/0"] == "2"
      assert arity["mcnodes/1"] == "2"
    end

    # [t] and [t | rest] both read as [:dynamic]: a list holding an
    # unknown has no length here.
    test "a list holding an unknown, a parameter, a fun, or no target has none",
         %{arity: arity} do
      for func <- ~w(apps_within/2 alive/2 erpc4/2 remote/5 erpc2/2 emulti3/2 yield1/1 recv1/1) do
        refute Map.has_key?(arity, func), func
      end
    end
  end

  describe "extract/1 — synchronous call timeouts" do
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

      assert Enum.any?(ops, fn [_id, func, op, retries, _nodes] ->
               String.contains?(func, "lock_default") and
                 op == "set_lock" and retries == "infinity"
             end)
    end

    test "records :global.set_lock/3 with retries=0 as non-blocking" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, op, retries, _nodes] ->
               String.contains?(func, "try_lock_once") and
                 op == "set_lock" and retries == "0"
             end)
    end

    test "records :global.set_lock/3 with explicit infinity retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, _op, retries, _nodes] ->
               String.contains?(func, "lock_infinity") and retries == "infinity"
             end)
    end

    test "records :global.set_lock/3 with positive integer retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, _op, retries, _nodes] ->
               String.contains?(func, "lock_with_retries") and retries == "5"
             end)
    end

    test "records :global.trans/2 as blocking with infinity retries" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, func, op, retries, _nodes] ->
               String.contains?(func, "trans_default") and
                 op == "trans" and retries == "infinity"
             end)
    end

    test "records :global.del_lock as non-blocking" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))
      ops = facts[:global_op]

      assert Enum.any?(ops, fn [_id, _func, op, retries, _nodes] ->
               op == "del_lock" and retries == "0"
             end)
    end
  end

  describe "extract/1 — :global node lists" do
    setup do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalNodes.Shapes))

      nodes =
        for [_id, func, op, _retries, nodes] <- facts[:global_op],
            do: {func |> String.split(":") |> List.last(), op, nodes}

      %{nodes: nodes}
    end

    test "a list of only the local node is local", %{nodes: nodes} do
      assert {"local/1", "set_lock", "local"} in nodes
      assert {"local_self/1", "set_lock", "local"} in nodes
      assert {"this/1", "set_lock", "local"} in nodes
      assert {"trans_local/2", "trans", "local"} in nodes
    end

    test "a list holding the connected nodes is cluster", %{nodes: nodes} do
      assert {"cluster/1", "set_lock", "cluster"} in nodes
      assert {"nodes_only/1", "set_lock", "cluster"} in nodes
      assert {"erl_nodes/1", "set_lock", "cluster"} in nodes
      assert {"appended/1", "set_lock", "cluster"} in nodes
      assert {"trans_cluster/2", "trans", "cluster"} in nodes
    end

    test "a list held in a variable is read where it was built", %{nodes: nodes} do
      assert {"held/1", "set_lock", "cluster"} in nodes
      assert {"held/1", "del_lock", "cluster"} in nodes
    end

    test "an omitted list means every known node", %{nodes: nodes} do
      assert {"default/1", "set_lock", "cluster"} in nodes
      assert {"trans_default/2", "trans", "cluster"} in nodes
    end

    test "a list the bytecode does not show is unknown", %{nodes: nodes} do
      assert {"arg/2", "set_lock", "unknown"} in nodes
      assert {"cons_arg/2", "set_lock", "unknown"} in nodes
      assert {"named/1", "set_lock", "unknown"} in nodes
    end

    test "a lookup and a send carry no node list" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GlobalLockModule))

      assert [[_id, _func, "whereis_name", "0", ""]] =
               Enum.filter(facts[:global_op], &(Enum.at(&1, 2) == "whereis_name"))
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
end
