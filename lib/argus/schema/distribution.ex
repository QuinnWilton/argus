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
          {:variant, :symbol,
           "RPC variant: rpc, block_call, multicall, yield, nb_yield (the :rpc functions), " <>
             "erpc, erpc_multicall, erpc_receive (:erpc.call, multicall, receive_response)"},
          {:timeout, :symbol,
           "timeout in ms, -1 for :infinity, 0 when unknown — as sync_call_timeout"}
        ],
        doc: """
        A remote call that waits for its answer, with its timeout: a call, \
        a multicall, or the collection of an answer an earlier async_call or \
        send_request asked for (yield, nb_yield/2, receive_response).
        """
      },
      %{
        name: :rpc_target,
        layer: 2,
        fields: [
          {:id, :symbol, "the rpc_call instruction ID"},
          {:target, :symbol,
           "the remote function as `Mod.fun` (`Process.alive?`, `:ets.lookup`), " <>
             "'fun' for the forms that take a fun, 'dynamic' when the site does not name it"}
        ],
        doc: """
        What an rpc_call runs on the other node, from its M and F arguments. \
        A yield or receive_response collects an answer another site asked \
        for, and names no target: 'dynamic'.
        """
      },
      %{
        name: :rpc_timeout_param,
        layer: 2,
        fields: [
          {:id, :symbol, "the rpc_call instruction ID"},
          {:param, :number, "0-based position of the function's parameter the timeout is"}
        ],
        doc: """
        An rpc_call whose timeout is one of its function's parameters on \
        every path (its timeout column says 0, unknown): a wrapper's \
        `timeout \\\\ :infinity`. With infinity_arg, the rules ask whether a \
        caller passes :infinity there.
        """
      },
      %{
        name: :rpc_arity,
        layer: 2,
        fields: [
          {:id, :symbol, "the rpc_call instruction ID"},
          {:arity, :number, "how many arguments the remote function is called with"}
        ],
        doc: """
        The length of the argument list an rpc_call hands its remote \
        function (rpc_target), when that list is known whole on every path: \
        a literal, or cons cells of known values ending in `[]`. \
        `:application.which_applications/0` waits at most gen_server's five \
        seconds; `/1` waits as long as its argument says.
        """
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
          {:retries, :symbol, "retry count: \"infinity\" | \"0\" | integer | \"dynamic\""},
          {:nodes, :symbol,
           "the nodes that take part: \"local\" | \"cluster\" | \"unknown\", empty for whereis_name and send"}
        ],
        doc: """
        `:global` synchronization primitives. The retries field is the third \
        argument of `:global.set_lock/3` (or `:global.trans/4`); analyses use \
        it to distinguish blocking calls (`infinity` or large positive \
        integers) from non-blocking try-once calls (`0`).

        `:global.set_lock/1,2` and `:global.trans/2,3` default to infinity \
        retries — recorded as `"infinity"` even when the source code omits \
        the argument.

        The nodes field is the node list's shape, which says whose \
        agreement the lock waits on: `"local"` for `[node()]` (only this \
        node's global server), `"cluster"` for a list holding the connected \
        nodes (`[node() | Node.list()]`, `Node.list()`) or an omitted list, \
        which means every known node, and `"unknown"` for a list the \
        bytecode does not show (`Argus.Extractor.Resolve.node_list/3`).
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
