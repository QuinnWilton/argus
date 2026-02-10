defmodule Argus.Test.Fixtures.CycleServerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask_b(server), do: GenServer.call(server, :ask_b)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask_b, _from, state) do
    # Sync-calls CycleServerB — creates half of a deadlock cycle.
    result = GenServer.call(Argus.Test.Fixtures.CycleServerB, :ping)
    {:reply, result, state}
  end
end

defmodule Argus.Test.Fixtures.CycleServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ask_a(server), do: GenServer.call(server, :ask_a)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:ask_a, _from, state) do
    # Sync-calls CycleServerA — completes the deadlock cycle.
    result = GenServer.call(Argus.Test.Fixtures.CycleServerA, :ping)
    {:reply, result, state}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end
end
