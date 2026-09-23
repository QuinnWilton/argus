defmodule Scry.RunnerDemandTest do
  @moduledoc """
  The analyses solve concurrently: each is its own Souffle process.
  """

  use ExUnit.Case, async: false

  alias Scry.Test.Fixture

  @moduletag :souffle
  @moduletag timeout: 300_000

  defmodule Spans do
    @moduledoc false
    def handle([:roux, :query, event], _measurements, %{query_name: :souffle_solve}, agent) do
      # Taken here, in the emitting process, not inside the agent.
      entry = {event, self(), System.monotonic_time()}
      Agent.update(agent, &[entry | &1])
    end

    def handle(_event, _measurements, _metadata, _agent), do: :ok
  end

  test "solves overlap in time, on more than one process" do
    copy = Fixture.checkout!(Path.join(System.tmp_dir!(), "scry_demand_depot"), [], :depot_demand)
    {:ok, agent} = Agent.start(fn -> [] end)
    id = {__MODULE__, agent}

    :telemetry.attach_many(
      id,
      [[:roux, :query, :start], [:roux, :query, :stop]],
      &Spans.handle/4,
      agent
    )

    try do
      Mix.Project.in_project(:depot_demand, copy, fn _module -> Fixture.compile!() end)
    after
      :telemetry.detach(id)
    end

    events = agent |> Agent.get(& &1) |> Enum.reverse()
    Agent.stop(agent)

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
