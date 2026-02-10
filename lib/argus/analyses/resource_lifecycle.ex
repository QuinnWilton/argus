defmodule Argus.Analyses.ResourceLifecycle do
  @moduledoc """
  Resource lifecycle analysis.

  Detects resource leaks: files, sockets, and ports opened without
  corresponding close calls in the same function or module.

  ## Output relations

  - `resource_leak(func, type)` — open without close in the same function.
  - `unclosed_port(func, port_type)` — port opened with no close in module.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :resource_lifecycle

  @impl true
  def description, do: "Resource leak detection: files, sockets, and ports"

  @impl true
  def rules_file, do: "analyses/resource_lifecycle.dl"

  @impl true
  def extractors, do: [Argus.Extractors.ResourceLifecycle]

  @impl true
  def output_relations do
    [
      %{
        name: :resource_leak,
        fields: [
          {:func, :symbol, "function with unmatched open"},
          {:type, :symbol, "resource type"}
        ],
        doc: "Resource opened without close in the same function."
      },
      %{
        name: :unclosed_port,
        fields: [
          {:func, :symbol, "function opening port"},
          {:port_type, :symbol, "port type"}
        ],
        doc: "Port opened with no close in module."
      }
    ]
  end
end
