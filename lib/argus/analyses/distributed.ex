defmodule Argus.Analyses.Distributed do
  @moduledoc """
  Distributed systems analysis.

  Detects distributed system anti-patterns: RPC calls without timeout,
  RPC in GenServer callbacks, global registration without conflict resolution,
  and distributed operations in init/1.

  ## Output relations

  - `rpc_without_timeout(func, variant)` — RPC call with default infinity timeout.
  - `rpc_in_genserver_callback(func, variant)` — RPC inside GenServer callback.
  - `global_register_risk(func, name)` — global.register_name without conflict resolution.
  - `global_blocking_op(func, op, retries)` — `:global.set_lock` / `:global.trans` with
    blocking retries (`infinity` or positive integer; `0` is excluded).
  - `global_blocking_in_init(func, op)` — blocking `:global` op reachable from `init/1`.
  - `distributed_in_init(func, op)` — distributed operation in init/1 blocking supervisor.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :distributed

  @impl true
  def description,
    do: "Distributed system anti-patterns: RPC timeouts, global races, init blocking"

  @impl true
  def rules_file, do: "analyses/distributed.dl"

  @impl true
  def extractors, do: [Argus.Extractors.Distributed, Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :rpc_without_timeout,
        fields: [
          {:func, :symbol, "function with infinity RPC"},
          {:variant, :symbol, "RPC variant"}
        ],
        doc: "RPC call with default infinity timeout."
      },
      %{
        name: :rpc_in_genserver_callback,
        fields: [
          {:func, :symbol, "GenServer callback"},
          {:variant, :symbol, "RPC variant"}
        ],
        doc: "RPC inside GenServer callback (compounds timeout risk)."
      },
      %{
        name: :global_register_risk,
        fields: [
          {:func, :symbol, "function"},
          {:name, :symbol, "global name"}
        ],
        doc: "global.register_name without conflict resolution callback."
      },
      %{
        name: :global_blocking_op,
        fields: [
          {:func, :symbol, "function calling :global"},
          {:op, :symbol, "operation: set_lock | trans | ..."},
          {:retries, :symbol, "resolved retries argument: infinity | positive integer"}
        ],
        doc:
          "Blocking :global synchronization (set_lock or trans with infinity or positive retries)."
      },
      %{
        name: :global_blocking_in_init,
        fields: [
          {:func, :symbol, "init function (or transitively reachable from one)"},
          {:op, :symbol, ":global operation"}
        ],
        doc: "Blocking :global op reachable from init/1 — hangs supervisor startup on netsplit."
      },
      %{
        name: :distributed_in_init,
        fields: [
          {:func, :symbol, "init function"},
          {:op, :symbol, "operation"}
        ],
        doc: "Distributed operation in init/1 blocking supervisor startup."
      }
    ]
  end
end
