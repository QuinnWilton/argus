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
