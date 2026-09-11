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

defmodule Argus.Test.Fixtures.ConditionalInitServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    # The sync call only happens when the caller opts in — postgrex's
    # sync_connect, goth's prefetch: :sync.
    if opts[:sync] do
      GenServer.call(Argus.Test.Fixtures.WorkerA, :ping)
    end

    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.StartsChildrenInInit do
  @moduledoc "The Broadway/Oban shape: children started synchronously from init/1."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(specs) do
    for spec <- specs do
      {:ok, _pid} = DynamicSupervisor.start_child(Argus.Test.Fixtures.PoolSup, spec)
    end

    {:ok, specs}
  end
end

defmodule Argus.Test.Fixtures.BlockingWatcher do
  @moduledoc """
  The db_connection Watcher: a singleton whose handle_info blocks in
  terminate_child for as long as a departing child takes to shut down.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def watch(pid), do: GenServer.call(__MODULE__, {:watch, pid}, :infinity)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {started, state} = Map.pop(state, ref)
    DynamicSupervisor.terminate_child(Argus.Test.Fixtures.PoolSup, started)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.WatchedPool do
  @moduledoc "Started by users, not by the app tree; its init waits on the singleton."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    :ok = Argus.Test.Fixtures.BlockingWatcher.watch(self())
    {:ok, opts}
  end
end

defmodule Argus.Test.Fixtures.WatcherAppTree do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Argus.Test.Fixtures.PoolSup},
      {Argus.Test.Fixtures.BlockingWatcher, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
