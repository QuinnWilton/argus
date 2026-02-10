defmodule Argus.Test.Fixtures.SyncInitServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    # Synchronous call during init — blocks startup until WorkerA responds.
    GenServer.call(Argus.Test.Fixtures.WorkerA, :ping)
    {:ok, %{}}
  end
end
