defmodule Argus.Test.Fixtures.GoodSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Argus.Test.Fixtures.WorkerA, []},
      {Argus.Test.Fixtures.WorkerB, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.BadOrderSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # WorkerB depends on WorkerA, but is started first — wrong order.
    children = [
      {Argus.Test.Fixtures.WorkerB, []},
      {Argus.Test.Fixtures.WorkerA, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.WorkerA do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}
end

defmodule Argus.Test.Fixtures.WorkerB do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def call_a(server), do: GenServer.call(server, :call_a)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:call_a, _from, state) do
    # This simulates calling WorkerA.
    {:reply, :ok, state}
  end
end
