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
    only: [add_fact: 3, resolve_register: 3, scan_remote_calls: 3, track_dynamic: 5]

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
  @spec extract(Argus.Extractor.module_data()) :: Argus.Pipeline.Emit.facts()
  def extract(module_data) do
    scan_remote_calls(module_data.module, module_data.functions, fn facts,
                                                                    ctx,
                                                                    {mod, func, arity} ->
      id = "#{ctx.func_id}##{ctx.idx}"

      facts
      |> maybe_rpc(id, ctx, mod, func, arity)
      |> maybe_global_register(id, ctx, mod, func, arity)
      |> maybe_global_op(id, ctx, mod, func, arity)
      |> maybe_node_op(id, ctx.func_id, mod, func, arity)
      |> maybe_distributed_store(id, ctx.func_id, mod, func, arity)
    end)
  end

  # RPC calls with timeout resolution.
  defp maybe_rpc(facts, id, ctx, :rpc, :call, 4) do
    # :rpc.call/4 — uses default infinity timeout.
    add_fact(facts, :rpc_call, [id, ctx.func_id, "rpc", "infinity"])
  end

  defp maybe_rpc(facts, id, ctx, :rpc, :call, 5) do
    # :rpc.call/5 — timeout is x4.
    timeout = resolve_timeout(ctx.instrs, ctx.idx, {:x, 4})

    facts
    |> track_dynamic(timeout, ctx, :rpc_timeout, :rpc_call)
    |> add_fact(:rpc_call, [id, ctx.func_id, "rpc", timeout])
  end

  defp maybe_rpc(facts, id, ctx, :rpc, :multicall, arity)
       when arity in [2, 3, 4] do
    # :rpc.multicall — default infinity timeout for 2,3,4-arity variants.
    add_fact(facts, :rpc_call, [id, ctx.func_id, "multicall", "infinity"])
  end

  defp maybe_rpc(facts, id, ctx, :rpc, :multicall, 5) do
    timeout = resolve_timeout(ctx.instrs, ctx.idx, {:x, 4})

    facts
    |> track_dynamic(timeout, ctx, :rpc_timeout, :rpc_call)
    |> add_fact(:rpc_call, [id, ctx.func_id, "multicall", timeout])
  end

  defp maybe_rpc(facts, id, ctx, :erpc, :call, 4) do
    # :erpc.call/4 — timeout is x3.
    timeout = resolve_timeout(ctx.instrs, ctx.idx, {:x, 3})

    facts
    |> track_dynamic(timeout, ctx, :rpc_timeout, :rpc_call)
    |> add_fact(:rpc_call, [id, ctx.func_id, "erpc", timeout])
  end

  defp maybe_rpc(facts, id, ctx, :erpc, :call, 5) do
    # :erpc.call/5 — timeout is x4.
    timeout = resolve_timeout(ctx.instrs, ctx.idx, {:x, 4})

    facts
    |> track_dynamic(timeout, ctx, :rpc_timeout, :rpc_call)
    |> add_fact(:rpc_call, [id, ctx.func_id, "erpc", timeout])
  end

  defp maybe_rpc(facts, id, ctx, :erpc, :multicall, arity)
       when arity in [4, 5] do
    timeout_reg = {:x, arity - 1}
    timeout = resolve_timeout(ctx.instrs, ctx.idx, timeout_reg)

    facts
    |> track_dynamic(timeout, ctx, :rpc_timeout, :rpc_call)
    |> add_fact(:rpc_call, [id, ctx.func_id, "erpc_multicall", timeout])
  end

  defp maybe_rpc(facts, _id, _ctx, _mod, _func, _arity), do: facts

  defp maybe_global_register(facts, id, ctx, :global, :register_name, arity)
       when arity in [2, 3] do
    name = resolve_name(ctx.instrs, ctx.idx)

    facts
    |> track_dynamic(name, ctx, :global_register_name, :global_register)
    |> add_fact(:global_register, [id, ctx.func_id, name])
  end

  defp maybe_global_register(facts, _id, _ctx, _mod, _func, _arity),
    do: facts

  # :global.set_lock/2 — uses default :infinity retries.
  defp maybe_global_op(facts, id, ctx, :global, :set_lock, 2) do
    add_fact(facts, :global_op, [id, ctx.func_id, "set_lock", "infinity"])
  end

  # :global.set_lock/3 — explicit retries argument in x2.
  defp maybe_global_op(facts, id, ctx, :global, :set_lock, 3) do
    retries = resolve_retries(ctx.instrs, ctx.idx, {:x, 2})

    facts
    |> track_dynamic(retries, ctx, :global_op_retries, :global_op)
    |> add_fact(:global_op, [id, ctx.func_id, "set_lock", retries])
  end

  # :global.del_lock/1,2 — non-blocking cleanup, retries don't apply but
  # we record it with "0" so blocking-classification rules treat it as safe.
  defp maybe_global_op(facts, id, ctx, :global, :del_lock, arity)
       when arity in [1, 2] do
    add_fact(facts, :global_op, [id, ctx.func_id, "del_lock", "0"])
  end

  # :global.trans/2,3 — internally calls set_lock with infinity retries.
  defp maybe_global_op(facts, id, ctx, :global, :trans, arity)
       when arity in [2, 3] do
    add_fact(facts, :global_op, [id, ctx.func_id, "trans", "infinity"])
  end

  # :global.trans/4 — explicit retries argument in x3.
  defp maybe_global_op(facts, id, ctx, :global, :trans, 4) do
    retries = resolve_retries(ctx.instrs, ctx.idx, {:x, 3})

    facts
    |> track_dynamic(retries, ctx, :global_op_retries, :global_op)
    |> add_fact(:global_op, [id, ctx.func_id, "trans", retries])
  end

  # :global.whereis_name/1, :global.send/2 — non-blocking lookups.
  defp maybe_global_op(facts, id, ctx, :global, :whereis_name, 1) do
    add_fact(facts, :global_op, [id, ctx.func_id, "whereis_name", "0"])
  end

  defp maybe_global_op(facts, id, ctx, :global, :send, 2) do
    add_fact(facts, :global_op, [id, ctx.func_id, "send", "0"])
  end

  defp maybe_global_op(facts, _id, _ctx, _mod, _func, _arity), do: facts

  # Resolve the retries argument: positive integer → string, :infinity →
  # "infinity", anything else → "dynamic". 0 retries means "try once and
  # return immediately if locked" — the only non-blocking variant.
  defp resolve_retries(instrs, idx, register) do
    case resolve_register(instrs, idx, register) do
      {:ok, 0} -> "0"
      {:ok, n} when is_integer(n) and n > 0 -> to_string(n)
      {:ok, :infinity} -> "infinity"
      _ -> "dynamic"
    end
  end

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
