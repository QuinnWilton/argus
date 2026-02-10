defmodule Argus.Test.Fixtures.BottleneckTarget do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get(key), do: GenServer.call(__MODULE__, {:get, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:get, _key}, _from, state), do: {:reply, :ok, state}
end

defmodule Argus.Test.Fixtures.BottleneckCallerA do
  @moduledoc false
  def fetch(key), do: Argus.Test.Fixtures.BottleneckTarget.get(key)
end

defmodule Argus.Test.Fixtures.BottleneckCallerB do
  @moduledoc false
  def fetch(key), do: Argus.Test.Fixtures.BottleneckTarget.get(key)
end

defmodule Argus.Test.Fixtures.BottleneckCallerC do
  @moduledoc false
  def fetch(key), do: Argus.Test.Fixtures.BottleneckTarget.get(key)
end

defmodule Argus.Test.Fixtures.BottleneckCallerD do
  @moduledoc false
  def fetch(key), do: Argus.Test.Fixtures.BottleneckTarget.get(key)
end

defmodule Argus.Test.Fixtures.BottleneckCallerE do
  @moduledoc false
  def fetch(key), do: Argus.Test.Fixtures.BottleneckTarget.get(key)
end
