defmodule Argus.Analyses.MessageFlow do
  @moduledoc """
  Message flow analysis.

  Identifies functions that send or receive messages and pairs potential
  senders with receivers across the call graph.

  ## Output relations

  - `sender_function(func)` — function contains a message send.
  - `receiver_function(func)` — function contains a receive block.
  - `send_recv_function(func)` — function both sends and receives.
  - `potential_message_path(sender_func, receiver_func)` — potential send/receive pairing.
  """

  @behaviour Argus.Analysis

  @impl true
  def name, do: :message_flow

  @impl true
  def description, do: "message send/receive pairing across functions"

  @impl true
  def rules_file, do: "analyses/message_flow.dl"

  @impl true
  def extractors, do: []

  @impl true
  def output_relations do
    [
      %{
        name: :sender_function,
        fields: [{:func, :symbol, "function ID"}],
        doc: "Function contains a message send instruction."
      },
      %{
        name: :receiver_function,
        fields: [{:func, :symbol, "function ID"}],
        doc: "Function contains a receive block."
      },
      %{
        name: :send_recv_function,
        fields: [{:func, :symbol, "function ID"}],
        doc: "Function both sends and receives messages."
      },
      %{
        name: :potential_message_path,
        fields: [
          {:sender_func, :symbol, "sender function ID"},
          {:receiver_func, :symbol, "receiver function ID"}
        ],
        doc: "Potential message path from sender to receiver."
      }
    ]
  end
end
