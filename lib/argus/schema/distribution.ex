defmodule Argus.Schema.Distribution do
  @moduledoc """
  Names and nodes: the process registry, `:global`, remote calls and the
  operations that reach across nodes.

  Layer 2 of `Argus.Schema`, which reads the relations from here.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    [
      %{
        name: :process_register,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:name, :symbol, "registered name atom"},
          {:method, :symbol, "registration method (register, start_link, start)"}
        ],
        doc: "Process name registration."
      },
      %{
        name: :rpc_call,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:variant, :symbol, "RPC variant (rpc, erpc, multicall)"},
          {:timeout, :symbol,
           "timeout in ms, -1 for :infinity, 0 when unknown — as sync_call_timeout"}
        ],
        doc: "RPC call with timeout information."
      },
      %{
        name: :global_register,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:name, :symbol, "global name"},
          {:arity, :symbol,
           "call arity: '2' (default conflict resolution) or '3' (explicit resolver)"}
        ],
        doc: """
        `:global.register_name` call. Arity distinguishes the race-prone \
        default (`/2`) from a call that supplies its own conflict-resolution \
        function (`/3`).
        """
      },
      %{
        name: :global_op,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:op, :symbol, "operation: set_lock | trans | del_lock | whereis_name | send"},
          {:retries, :symbol, "retry count: \"infinity\" | \"0\" | integer | \"dynamic\""}
        ],
        doc: """
        `:global` synchronization primitives. The retries field is the third \
        argument of `:global.set_lock/3` (or `:global.trans/4`); analyses use \
        it to distinguish blocking calls (`infinity` or large positive \
        integers) from non-blocking try-once calls (`0`).

        `:global.set_lock/2` and `:global.trans/2,3` default to infinity \
        retries — recorded as `"infinity"` even when the source code omits \
        the argument.
        """
      },
      %{
        name: :node_operation,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:op, :symbol, "operation (connect, disconnect, spawn, ping, etc.)"}
        ],
        doc: "Node or :net_kernel operation."
      },
      %{
        name: :distributed_store_op,
        layer: 2,
        fields: [
          {:id, :symbol, "instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:store, :symbol, "store type (mnesia or dets)"},
          {:op, :symbol, "operation name"}
        ],
        doc: "Mnesia or DETS distributed store operation."
      }
    ]
  end
end
