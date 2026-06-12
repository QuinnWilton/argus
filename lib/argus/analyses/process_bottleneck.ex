defmodule Argus.Analyses.ProcessBottleneck do
  @moduledoc """
  Process bottleneck detection.

  Identifies GenServer modules with high synchronous call fan-in: 5 or more
  distinct caller modules make `GenServer.call` to the same target. These are
  serialization points that can become throughput bottlenecks under load.

  Low fan-in GenServers (1–4 callers) are normal centralized services and are
  not reported.

  Requires the OTP extractor for `sync_call` and `implements_behaviour` facts.

  ## Output relations

  - `bottleneck_caller(caller_mod, target_mod)` — caller of a high-fan-in GenServer.
  - `sync_call_fan_in(target_mod, count)` — number of distinct callers (>= 5 only).

  ## Finding severities

  - `sync_call_fan_in` — `:warning`. The headline finding: a single
    process serializing five or more caller modules is a throughput
    ceiling waiting for load.
  - `bottleneck_caller` — `:info`. Supporting evidence: one row per
    caller of the bottleneck.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :process_bottleneck

  @impl true
  def description, do: "synchronous call fan-in (serialization bottleneck) detection"

  @impl true
  def rules_file, do: "analyses/process_bottleneck.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP, Argus.Extractors.GenEvent]

  @impl true
  def output_relations do
    [
      %{
        name: :bottleneck_caller,
        fields: [
          {:caller_mod, :symbol, "module making the sync call"},
          {:target_mod, :symbol, "target GenServer module"}
        ],
        doc: "Caller of a high-fan-in (>= 5) GenServer."
      },
      %{
        name: :sync_call_fan_in,
        fields: [
          {:target_mod, :symbol, "target GenServer module"},
          {:cnt, :number, "number of distinct caller modules"}
        ],
        doc: "Synchronous call fan-in count for a GenServer (>= 5 only)."
      }
    ]
  end

  @impl true
  def finding(:sync_call_fan_in, [target_mod, cnt]) do
    Findings.new(
      :warning,
      "High synchronous fan-in (#{cnt} caller modules)",
      "#{cnt} distinct modules make GenServer.call into #{target_mod}. A " <>
        "single process serializes all of them — under load, queue depth and " <>
        "call latency grow together until callers start timing out. Consider " <>
        "sharding, ETS for reads, or casts where replies aren't needed.",
      at: Findings.at_module(target_mod)
    )
  end

  def finding(:bottleneck_caller, [caller_mod, target_mod]) do
    Findings.new(
      :info,
      "Caller of a high fan-in GenServer",
      "#{caller_mod} synchronously calls #{target_mod}, one of #{target_mod}'s " <>
        "five-plus caller modules. Each such call competes for the same " <>
        "serialized mailbox.",
      at: Findings.at_module(caller_mod),
      related: [Findings.related("bottleneck", Findings.at_module(target_mod))]
    )
  end
end
