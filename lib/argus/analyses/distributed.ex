defmodule Argus.Analyses.Distributed do
  @moduledoc """
  Distributed systems analysis.

  Detects distributed system anti-patterns: RPC calls without timeout,
  RPC in GenServer callbacks, global registration without conflict resolution,
  and distributed operations in init/1.

  ## Output relations

  - `rpc_without_timeout(func, variant)` — RPC call with default infinity timeout.
  - `rpc_in_genserver_callback(func, variant)` — RPC directly inside a GenServer callback.
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
  def extractors,
    do: [Argus.Extractors.ApiCalls, Argus.Extractors.OTP, Argus.Extractors.ErrorHandling]

  @impl true
  def output_relations do
    [
      %{
        name: :erpc_transport_unhandled,
        fields: [
          {:func, :symbol, "function calling :erpc.call"},
          {:site, :symbol, "the try"}
        ],
        doc:
          "A rescue around :erpc.call unwraps remote exceptions but has no clause for transport failures."
      },
      %{
        name: :rpc_result_unhandled,
        fields: [
          {:func, :symbol, "function making the rpc"},
          {:site, :symbol, "the rpc call"},
          {:variant, :symbol, "rpc | multicall | erpc"},
          {:shape, :symbol, "'case' (matched by shape, no clause) or 'boolean' (truthy tuple)"}
        ],
        key: [:func, :site],
        doc: "An rpc result whose failure value is not handled."
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
  def finding(:erpc_transport_unhandled, [func, site]) do
    Findings.new(
      :warning,
      ":erpc.call transport failures fall through the rescue",
      "#{func} rescues the ErlangError :erpc.call raises and unwraps the " <>
        "`{:exception, _, _}` a remote raise produces, but a node going away " <>
        "raises `{:erpc, :noconnection}` (or `{:erpc, :timeout}`, " <>
        "`{:erpc, :system_limit}`), and the rescue's `case` has no clause for " <>
        "it — a CaseClauseError in place of a result.",
      at: Findings.at_site(site, func),
      at_label: "rescue without an {:erpc, _} clause",
      help: ["add a clause for `{:erpc, reason}` and return or raise a meaningful error"]
    )
  end

  def finding(:rpc_result_unhandled, [func, site, "erpc", "boolean"]) do
    Findings.new(
      :warning,
      ":erpc.call in a boolean context with no rescue",
      "#{func} uses the result of :erpc.call as a boolean. A node that went " <>
        "away between the check that chose it and the call raises " <>
        "`{:erpc, :noconnection}` here, and nothing rescues it.",
      at: Findings.at_site(site, func),
      at_label: "raises on a gone node",
      help: ["rescue ErlangError with `{:erpc, :noconnection}` and treat it as false"]
    )
  end

  def finding(:rpc_result_unhandled, [func, site, variant, "boolean"]) do
    Findings.new(
      :warning,
      "RPC result used as a boolean",
      "#{func} uses the result of :rpc.#{variant} as a boolean. A node that is " <>
        "gone answers `{:badrpc, :nodedown}` (a timeout `{:badrpc, :timeout}`), " <>
        "and a tuple is truthy: the failure reads as true.",
      at: Findings.at_site(site, func),
      at_label: "{:badrpc, _} is truthy here",
      help: ["match `{:badrpc, _}` explicitly before treating the result as a boolean"]
    )
  end

  def finding(:rpc_result_unhandled, [func, site, variant, _shape]) do
    Findings.new(
      :warning,
      "RPC result matched without a {:badrpc, _} clause",
      "#{func} matches the result of :rpc.#{variant} by shape and has no clause " <>
        "for `{:badrpc, reason}` — a node that is down, a timeout, a remote " <>
        "exit — so a cluster failure is a CaseClauseError (or MatchError) " <>
        "instead of an error value.",
      at: Findings.at_site(site, func),
      at_label: "no {:badrpc, _} clause",
      help: ["add a `{:badrpc, reason} -> {:error, reason}` clause, or move to :erpc and rescue"]
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
