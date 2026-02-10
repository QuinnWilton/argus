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
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :process_bottleneck

  @impl true
  def description, do: "synchronous call fan-in (serialization bottleneck) detection"

  @impl true
  def rules_file, do: "process_bottleneck.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP]

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
end
