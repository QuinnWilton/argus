defmodule Argus.Analyses.ProcessBottleneck do
  @moduledoc """
  Process bottleneck detection.

  Identifies GenServer modules with high synchronous call fan-in: many distinct
  caller modules make `GenServer.call` to the same target. These are
  serialization points that can become throughput bottlenecks under load.

  Requires the OTP extractor for `sync_call` and `implements_behaviour` facts.

  ## Output relations

  - `sync_caller(caller_mod, target_mod)` — module-level sync call dependency.
  - `sync_call_fan_in(target_mod, count)` — number of distinct callers for each GenServer.
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
        name: :sync_caller,
        fields: [
          {:caller_mod, :symbol, "module making the sync call"},
          {:target_mod, :symbol, "target GenServer module"}
        ],
        doc: "Module-level synchronous call dependency."
      },
      %{
        name: :sync_call_fan_in,
        fields: [
          {:target_mod, :symbol, "target GenServer module"},
          {:cnt, :number, "number of distinct caller modules"}
        ],
        doc: "Synchronous call fan-in count for a GenServer."
      }
    ]
  end
end
