defmodule Scry.Test.QueryLog do
  @moduledoc """
  Telemetry collector for edit-replay assertions: records which roux
  queries executed, cache-hit, or early-cutoff during a block, so tests
  can assert the EXACT recompute set for an edit. (The planchette
  pattern, verbatim.)
  """

  @events [
    [:roux, :query, :start],
    [:roux, :cache, :hit],
    [:roux, :cache, :early_cutoff]
  ]

  @doc """
  Starts a collector agent and attaches telemetry handlers. Returns the
  agent pid; call `detach/1` (or rely on the test process exit) when done.
  """
  @spec start() :: pid()
  def start do
    # Unlinked: detach/1 runs from on_exit, after the test process died.
    {:ok, agent} = Agent.start(fn -> [] end)
    id = {__MODULE__, agent}

    :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, agent)

    agent
  end

  @doc false
  def handle_event(event, _measurements, metadata, agent) do
    entry = {Enum.at(event, 2), metadata.query_name, metadata.key}
    Agent.update(agent, &[entry | &1])
  end

  @spec detach(pid()) :: :ok
  def detach(agent) do
    :telemetry.detach({__MODULE__, agent})
    Agent.stop(agent)
    :ok
  end

  @doc "Clears collected entries (start of a replay round)."
  @spec reset(pid()) :: :ok
  def reset(agent), do: Agent.update(agent, fn _ -> [] end)

  @doc "Keys for which `query_name` actually re-executed, sorted."
  @spec executions(pid(), atom()) :: [term()]
  def executions(agent, query_name) do
    agent
    |> entries()
    |> Enum.filter(fn {kind, name, _key} -> kind == :start and name == query_name end)
    |> Enum.map(fn {_kind, _name, key} -> key end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Keys for which `query_name` early-cutoff, sorted."
  @spec cutoffs(pid(), atom()) :: [term()]
  def cutoffs(agent, query_name) do
    agent
    |> entries()
    |> Enum.filter(fn {kind, name, _key} -> kind == :early_cutoff and name == query_name end)
    |> Enum.map(fn {_kind, _name, key} -> key end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp entries(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()
end
