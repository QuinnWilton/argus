defmodule Argus.Test.Fixtures.MyGenServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def get_value(server), do: GenServer.call(server, :get)

  def set_value(server, val), do: GenServer.cast(server, {:set, val})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:set, val}, _state), do: {:noreply, val}
end

defmodule Argus.Test.Fixtures.PlainModule do
  @moduledoc false

  def hello, do: :world
end
