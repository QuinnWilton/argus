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

  ## Finding severities

  - `global_blocking_in_init` — `:error`. init blocks the supervisor and
    the lock blocks on cluster-wide agreement; a netsplit turns local
    startup into an indefinite hang.
  - `rpc_without_timeout`, `rpc_in_genserver_callback`,
    `global_register_risk`, `distributed_in_init` — `:warning`. Remote
    latency or partition behavior leaking into local liveness.
  - `global_blocking_op` — `:info`. Cluster-wide locking is legitimate
    when deliberate; flagged so the serialization point is visible.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

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
          {:variant, :symbol, "RPC variant"},
          {:site, :symbol, "instruction ID of the RPC call"}
        ],
        key: [:func, :variant],
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
          {:name, :symbol, "global name"},
          {:site, :symbol, "instruction ID of the registration"}
        ],
        key: [:func, :name],
        doc: "global.register_name without conflict resolution callback."
      },
      %{
        name: :global_blocking_op,
        fields: [
          {:func, :symbol, "function calling :global"},
          {:op, :symbol, "operation: set_lock | trans | ..."},
          {:retries, :symbol, "resolved retries argument: infinity | positive integer"},
          {:site, :symbol, "instruction ID of the :global call"}
        ],
        key: [:func, :op, :retries],
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
          {:op, :symbol, "operation"},
          {:site, :symbol, "instruction ID of the operation inside init"}
        ],
        key: [:func, :op],
        doc: "Distributed operation in init/1 blocking supervisor startup."
      }
    ]
  end

  @impl true
  def finding(:rpc_without_timeout, [func, variant, site]) do
    Findings.new(
      :warning,
      "RPC without a timeout",
      "#{func} uses #{variant} with the default infinity timeout. A " <>
        "partitioned, overloaded, or restarting peer blocks this process " <>
        "indefinitely — distributed calls need explicit deadlines.",
      at: Findings.at_instr(site)
    )
  end

  def finding(:rpc_in_genserver_callback, [func, variant]) do
    Findings.new(
      :warning,
      "RPC inside a GenServer callback",
      "#{func} performs #{variant} while its GenServer is blocked in a " <>
        "callback. Remote latency becomes local unavailability: every queued " <>
        "caller waits on the network round-trip, and a peer outage stalls " <>
        "the whole server.",
      at: Findings.at_func(func)
    )
  end

  def finding(:global_register_risk, [func, name, site]) do
    Findings.new(
      :warning,
      ":global registration without conflict resolution",
      "#{func} registers #{name} via :global without a resolve function. " <>
        "After a netsplit heals, both partitions hold the name and the " <>
        "default resolution kills one of the processes at random — state " <>
        "loss decided by a coin flip.",
      at: Findings.at_instr(site)
    )
  end

  def finding(:global_blocking_op, [func, op, retries, site]) do
    Findings.new(
      :info,
      "Cluster-wide :global synchronization",
      "#{func} calls :global.#{op} with retries = #{retries}. :global " <>
        "operations serialize across the whole cluster — fine when " <>
        "deliberate, but every caller shares one distributed lock, and " <>
        "partition recovery stalls them all.",
      at: Findings.at_instr(site)
    )
  end

  def finding(:global_blocking_in_init, [func, op]) do
    Findings.new(
      :error,
      "Cluster-wide lock during init",
      "#{func} reaches :global.#{op} from init/1. init blocks the " <>
        "supervisor's start sequence, and the :global op blocks on " <>
        "cluster-wide agreement — local startup now hangs whenever the " <>
        "cluster is partitioned or slow. Defer to handle_continue.",
      at: Findings.at_func(func)
    )
  end

  def finding(:distributed_in_init, [func, op, site]) do
    Findings.new(
      :warning,
      "Distributed operation in init/1",
      "#{func} performs #{op} during init, while the supervisor's start " <>
        "sequence waits. A slow or partitioned peer stalls local startup; " <>
        "defer remote work to handle_continue so the tree boots without the " <>
        "network.",
      at: Findings.at_instr(site)
    )
  end
end
