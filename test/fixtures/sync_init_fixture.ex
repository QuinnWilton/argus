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

defmodule Argus.Test.Fixtures.SafeOrderSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # WorkerA starts first, SyncInitServer second — safe ordering.
    children = [
      {Argus.Test.Fixtures.WorkerA, []},
      {Argus.Test.Fixtures.SyncInitServer, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.DeadlockOrderSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # SyncInitServer calls WorkerA, but WorkerA starts later — deadlock.
    children = [
      {Argus.Test.Fixtures.SyncInitServer, []},
      {Argus.Test.Fixtures.WorkerA, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.DisjointSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [{Argus.Test.Fixtures.WorkerA, []}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.CallerSupervisor do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [{Argus.Test.Fixtures.SyncInitServer, []}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
