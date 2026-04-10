defmodule Argus.Extractors.Distributed do
  @moduledoc """
  Distributed systems extractor.

  Detects RPC calls, global name registration, node operations, and
  distributed store operations. `:rpc.call` with infinity timeout hangs
  on netsplit. `:global.register_name` races during partitions. These
  bugs are invisible in testing and cause severe production outages.

  ## Emitted facts

  - `rpc_call(id, func, variant, timeout)` — `:rpc.call/4,5`, `:erpc.call/4,5`
  - `global_register(id, func, name)` — `:global.register_name/2,3`
  - `node_operation(id, func, op)` — `Node.connect/disconnect/spawn`, `:net_kernel`
  - `distributed_store_op(id, func, store, op)` — `:mnesia.read/write/transaction`
  """

  @behaviour Argus.Extractor

  import Argus.Extractor.Helpers,
    only: [add_fact: 3, resolve_register: 3, scan_remote_calls: 3]

  # Node operations to detect.
  @node_ops [
    {Node, :connect, 1},
    {Node, :disconnect, 1},
    {Node, :spawn, 2},
    {Node, :spawn, 3},
    {Node, :spawn, 4},
    {Node, :spawn, 5},
    {Node, :spawn_link, 2},
    {Node, :spawn_link, 3},
    {Node, :spawn_link, 4},
    {Node, :spawn_link, 5},
    {Node, :ping, 1},
    {Node, :list, 0},
    {Node, :list, 1},
    {Node, :monitor, 2},
    {:net_kernel, :connect_node, 1},
    {:net_kernel, :monitor_nodes, 1},
    {:net_kernel, :monitor_nodes, 2}
  ]

  # Mnesia operations.
  @mnesia_ops MapSet.new([
                :read,
                :write,
                :delete,
                :delete_object,
                :first,
                :next,
                :last,
                :prev,
                :match_object,
                :select,
                :index_read,
                :dirty_read,
                :dirty_write,
                :dirty_delete,
                :dirty_first,
                :dirty_next,
                :dirty_last,
                :dirty_match_object,
                :dirty_index_read,
                :transaction,
                :activity,
                :sync_transaction,
                :async_dirty,
                :sync_dirty,
                :create_table,
                :delete_table,
                :add_table_index,
                :add_table_copy,
                :change_table_copy_type
              ])

  # DETS operations.
  @dets_ops MapSet.new([
              :open_file,
              :close,
              :lookup,
              :insert,
              :delete,
              :match_object,
              :select,
              :first,
              :next,
              :sync,
              :info
            ])

  @impl true
  @spec extract(Argus.Extractor.module_data()) :: Argus.Emitter.facts()
  def extract(module_data) do
    scan_remote_calls(module_data.module, module_data.functions, fn facts, ctx, {mod, func, arity} ->
      id = "#{ctx.func_id}##{ctx.idx}"

      facts
      |> maybe_rpc(id, ctx.func_id, mod, func, arity, ctx.instrs, ctx.idx)
      |> maybe_global_register(id, ctx.func_id, mod, func, arity, ctx.instrs, ctx.idx)
      |> maybe_node_op(id, ctx.func_id, mod, func, arity)
      |> maybe_distributed_store(id, ctx.func_id, mod, func, arity)
    end)
  end

  # RPC calls with timeout resolution.
  defp maybe_rpc(facts, id, func_id, :rpc, :call, 4, _instrs, _idx) do
    # :rpc.call/4 — uses default infinity timeout.
    add_fact(facts, :rpc_call, [id, func_id, "rpc", "infinity"])
  end

  defp maybe_rpc(facts, id, func_id, :rpc, :call, 5, instrs, idx) do
    # :rpc.call/5 — timeout is x4.
    timeout = resolve_timeout(instrs, idx, {:x, 4})
    add_fact(facts, :rpc_call, [id, func_id, "rpc", timeout])
  end

  defp maybe_rpc(facts, id, func_id, :rpc, :multicall, arity, _instrs, _idx)
       when arity in [2, 3, 4] do
    # :rpc.multicall — default infinity timeout for 2,3,4-arity variants.
    add_fact(facts, :rpc_call, [id, func_id, "multicall", "infinity"])
  end

  defp maybe_rpc(facts, id, func_id, :rpc, :multicall, 5, instrs, idx) do
    timeout = resolve_timeout(instrs, idx, {:x, 4})
    add_fact(facts, :rpc_call, [id, func_id, "multicall", timeout])
  end

  defp maybe_rpc(facts, id, func_id, :erpc, :call, 4, instrs, idx) do
    # :erpc.call/4 — timeout is x3.
    timeout = resolve_timeout(instrs, idx, {:x, 3})
    add_fact(facts, :rpc_call, [id, func_id, "erpc", timeout])
  end

  defp maybe_rpc(facts, id, func_id, :erpc, :call, 5, instrs, idx) do
    # :erpc.call/5 — timeout is x4.
    timeout = resolve_timeout(instrs, idx, {:x, 4})
    add_fact(facts, :rpc_call, [id, func_id, "erpc", timeout])
  end

  defp maybe_rpc(facts, id, func_id, :erpc, :multicall, arity, instrs, idx)
       when arity in [4, 5] do
    timeout_reg = {:x, arity - 1}
    timeout = resolve_timeout(instrs, idx, timeout_reg)
    add_fact(facts, :rpc_call, [id, func_id, "erpc_multicall", timeout])
  end

  defp maybe_rpc(facts, _id, _func_id, _mod, _func, _arity, _instrs, _idx), do: facts

  defp maybe_global_register(facts, id, func_id, :global, :register_name, arity, instrs, idx)
       when arity in [2, 3] do
    name = resolve_name(instrs, idx)
    add_fact(facts, :global_register, [id, func_id, name])
  end

  defp maybe_global_register(facts, _id, _func_id, _mod, _func, _arity, _instrs, _idx),
    do: facts

  defp maybe_node_op(facts, id, func_id, mod, func, arity) do
    if {mod, func, arity} in @node_ops do
      add_fact(facts, :node_operation, [id, func_id, to_string(func)])
    else
      facts
    end
  end

  defp maybe_distributed_store(facts, id, func_id, :mnesia, func, _arity) do
    if MapSet.member?(@mnesia_ops, func) do
      add_fact(facts, :distributed_store_op, [id, func_id, "mnesia", to_string(func)])
    else
      facts
    end
  end

  defp maybe_distributed_store(facts, id, func_id, :dets, func, _arity) do
    if MapSet.member?(@dets_ops, func) do
      add_fact(facts, :distributed_store_op, [id, func_id, "dets", to_string(func)])
    else
      facts
    end
  end

  defp maybe_distributed_store(facts, _id, _func_id, _mod, _func, _arity), do: facts

  defp resolve_timeout(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, n} when is_integer(n) and n > 0 -> to_string(n)
      {:ok, :infinity} -> "infinity"
      _ -> "dynamic"
    end
  end

  defp resolve_name(instrs, idx) do
    case resolve_register(instrs, idx, {:x, 0}) do
      {:ok, atom} when is_atom(atom) -> inspect(atom)
      _ -> "dynamic"
    end
  end
end
