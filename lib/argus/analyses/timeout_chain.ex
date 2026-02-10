defmodule Argus.Analyses.TimeoutChain do
  @moduledoc """
  GenServer timeout chain detection.

  Detects two dangerous patterns in GenServer callback implementations:

  1. **Timeout chains** — `handle_call/3` callbacks that make synchronous
     calls to other GenServer modules, which in turn make their own sync
     calls. `GenServer.call` defaults to 5000ms, and when handle_call
     makes downstream sync calls, timeouts compose unpredictably: a chain
     A→B→C means A's timeout must accommodate B+C latency.

  2. **Blocking cast handlers** — `handle_cast/2` callbacks that make
     synchronous calls, defeating the async purpose of cast and silently
     blocking the GenServer.

  Requires the OTP extractor for behaviour and sync_call facts.

  ## Output relations

  - `timeout_chain_risk(from, to, depth)` — chain of depth >= 2 through GenServer handle_call callbacks.
  - `blocking_cast_handler(mod, target)` — handle_cast that blocks on a sync call.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :timeout_chain

  @impl true
  def description, do: "GenServer timeout chain and blocking cast handler detection"

  @impl true
  def rules_file, do: "timeout_chain.dl"

  @impl true
  def extractors, do: [Argus.Extractors.OTP]

  @impl true
  def output_relations do
    [
      %{
        name: :timeout_chain_risk,
        fields: [
          {:from, :symbol, "outermost GenServer module"},
          {:to, :symbol, "innermost GenServer module"},
          {:depth, :number, "chain depth (>= 2)"}
        ],
        doc: "Timeout chain through GenServer handle_call callbacks."
      },
      %{
        name: :blocking_cast_handler,
        fields: [
          {:mod, :symbol, "GenServer module with blocking cast"},
          {:target, :symbol, "sync call target module"}
        ],
        doc: "handle_cast/2 that makes a synchronous call."
      }
    ]
  end
end
