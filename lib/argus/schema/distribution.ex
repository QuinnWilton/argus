defmodule Argus.Schema.Distribution do
  @moduledoc """
  Layer-2 facts for process registries, `:global`, RPC, and cross-node operations. \
  Exposed through `Argus.Schema`.
  """

  @doc "The relations, in the order `Argus.Schema.all/0` lists them."
  @spec relations() :: [Argus.Schema.declaration()]
  def relations do
    Argus.Schema.Reads.record("relations #{__MODULE__}", [
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
          {:timeout, :number,
           "timeout in ms, -1 for :infinity, 0 when unknown — as sync_call_timeout"}
        ],
        doc: """
        A remote call that waits for an answer, with its timeout. Includes multicalls \
        and collection of earlier asynchronous requests via yield or receive-response \
        APIs.
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
        The remote module and function of an `rpc_call`. Response-collection sites such \
        as yield or receive-response use `dynamic` because another site initiated the \
        request.
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
        An `rpc_call` whose timeout is a function parameter on every path. Its timeout \
        column is 0 (unknown); `infinity_arg` identifies callers passing `:infinity`.
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
        The RPC argument-list length when the complete list is known on every path. \
        Distinguishes remote function arities, which may have different timeout \
        behavior.
        """
      },
      %{
        name: :rpc_callee,
        layer: 2,
        fields: [
          {:id, :symbol, "the rpc_call instruction ID"},
          {:func, :symbol, "containing function ID"},
          {:mod, :symbol, "the remote module, inspected as function_def spells it"},
          {:callee, :symbol, "the remote function's ID, `Mod:fun/arity`"}
        ],
        doc: """
        An RPC target in `function_def` MFA format, when module and function are literal \
        and argument-list length is known on every path. List element values need not be \
        known.
        """
      },
      %{
        name: :rpc_mfa_param,
        layer: 2,
        fields: [
          {:id, :symbol, "the rpc_call instruction ID"},
          {:func, :symbol,
           "the function whose parameters the three are: the rpc's own, or the " <>
             "one that built the closure the rpc is in"},
          {:pos, :number,
           "0-based position of the module parameter; the function's is pos + 1, the arguments' pos + 2"}
        ],
        doc: """
        An RPC wrapper whose module, function, and argument list come from three \
        consecutive parameters on every path. Captured variables are traced to the \
        enclosing function's parameters; closures constructed at multiple sites are \
        excluded.
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
        A `:global.register_name` call. Arity 2 uses default conflict resolution; arity \
        3 supplies a resolver.
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
        A `:global` synchronization operation. Retries are `0` for try-once, a positive \
        count, or `infinity`; omitted retries default to `infinity`. Node scope is \
        `local` for `[node()]`, `cluster` for connected-node lists or the default, and \
        `unknown` when unresolved (`Argus.Extractor.Resolve.node_list/3`).
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
          {:store, :symbol, "store type (mnesia)"},
          {:op, :symbol, "operation name"}
        ],
        doc:
          "Mnesia distributed store operation. DETS is not one: a DETS table is a file " <>
            "on its own node."
      }
    ])
  end
end
