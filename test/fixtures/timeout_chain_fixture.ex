defmodule Argus.Test.Fixtures.TimeoutChain.ServerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get_data(server), do: GenServer.call(server, :get_data)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get_data, _from, state) do
    # Synchronous call to ServerB during handle_call — creates a chain.
    result = Argus.Test.Fixtures.TimeoutChain.ServerB.fetch(state.server_b)
    {:reply, result, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ServerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def fetch(server), do: GenServer.call(server, :fetch)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:fetch, _from, state) do
    # Synchronous call to ServerC — extends the chain to depth 2.
    val = Argus.Test.Fixtures.TimeoutChain.ServerC.lookup(state.server_c)
    {:reply, val, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.ServerC do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def lookup(server), do: GenServer.call(server, :lookup)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:lookup, _from, state) do
    {:reply, state.value, state}
  end
end

defmodule Argus.Test.Fixtures.TimeoutChain.BlockingCastServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def notify(server, msg), do: GenServer.cast(server, {:notify, msg})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:notify, _msg}, state) do
    # Synchronous call inside handle_cast — defeats the async purpose.
    _val = Argus.Test.Fixtures.TimeoutChain.ServerC.lookup(state.server_c)
    {:noreply, state}
  end
end
