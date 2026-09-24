defmodule Scry.RunnerDemandTest do
  @moduledoc """
  The analyses solve concurrently: each is its own Souffle process. In
  its own peer (`Scry.Test.Peer`): the Mix project stack, the working
  directory and telemetry handlers are VM-wide.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Scry.Test.{Fixture, Peer}

  @moduletag :souffle
  @moduletag timeout: 300_000

  @doc false
  def handle([:roux, :query, event], _measurements, %{query_name: :souffle_solve}, agent) do
    # Taken here, in the emitting process, not inside the agent; the pid
    # as text, since it comes back from the peer.
    entry = {event, inspect(self()), System.monotonic_time()}
    Agent.update(agent, &[entry | &1])
  end

  def handle(_event, _measurements, _metadata, _agent), do: :ok

  test "solves overlap in time, on more than one process" do
    # Two solves are enough to overlap; the others would only add time.
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_demand_depot"),
        [analyses: [:coupling, :mailbox]],
        :depot_demand
      )

    events =
      Fixture.in_peer(Peer.start!(), copy, :depot_demand, fn _log ->
        {:ok, agent} = Agent.start(fn -> [] end)
        id = {__MODULE__, agent}

        :telemetry.attach_many(
          id,
          [[:roux, :query, :start], [:roux, :query, :stop]],
          &__MODULE__.handle/4,
          agent
        )

        try do
          Fixture.compile!()
        after
          :telemetry.detach(id)
        end

        events = agent |> Agent.get(& &1) |> Enum.reverse()
        Agent.stop(agent)
        events
      end)

    assert length(for({:start, _, _} <- events, do: 1)) > 1
    assert events |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() > 1

    # Some solve starts before another has stopped.
    {overlap, _open} =
      Enum.reduce(events, {false, 0}, fn
        {:start, _, _}, {overlap, open} -> {overlap or open > 0, open + 1}
        {:stop, _, _}, {overlap, open} -> {overlap, open - 1}
      end)

    assert overlap
  end
end
