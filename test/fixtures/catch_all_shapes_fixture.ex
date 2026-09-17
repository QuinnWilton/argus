defmodule Argus.Test.Fixtures.CatchAllShapes do
  @moduledoc false

  defmodule StatePatternCatchAll do
    @moduledoc false
    # gen_stage's fix for #238: the last clause accepts every message and
    # patterns the state — a catch-all for messages.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, {[], nil}}

    @impl true
    def handle_info(:stop, state), do: {:stop, :normal, state}
    def handle_info(_msg, {stack, continuation}), do: {:noreply, {stack, continuation}}
  end

  defmodule MapAccessBody do
    @moduledoc false
    # Two clauses, no catch-all; each body reads the state map, which
    # compiles to a test on the state before the body proper.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %{acks: %{}, waiting: %{}}}

    @impl true
    def handle_cast({:ack, id, count}, state) do
      acks = Map.update(state.acks, id, count, &(&1 + count))
      {:noreply, %{state | acks: acks}}
    end

    def handle_cast({:rebalance, id}, state) do
      {:noreply, %{state | waiting: Map.delete(state.waiting, id)}}
    end
  end
end
