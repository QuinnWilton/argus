# Startup and coupling shapes argus once misread, each beside a twin
# that keeps the defect and stays reported.

# init/1 reads a local DETS table the caller opened before the start: a
# file on this node, with no peer to wait on.
defmodule Argus.Test.Fixtures.StartupDetsInInit do
  @moduledoc false
  use GenServer

  def start_link(_) do
    :dets.open_file(:startup_counts, type: :set, ram_file: true)
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    case :dets.lookup(:startup_counts, __MODULE__) do
      [] -> {:ok, state}
      [{__MODULE__, count}] -> {:ok, Map.put(state, :count, count)}
    end
  end
end

# The twin: init/1 reads a Mnesia table, which may wait on another node.
defmodule Argus.Test.Fixtures.StartupMnesiaInInit do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    case :mnesia.dirty_read(:startup_counts, __MODULE__) do
      [] -> {:ok, state}
      [{:startup_counts, __MODULE__, count}] -> {:ok, Map.put(state, :count, count)}
    end
  end
end

# init/1 keeps a local capture of a helper that starts a child, as the
# default of an option, and runs it from a handler later. The capture is
# a fun value init/1 stores, not a call it makes.
defmodule Argus.Test.Fixtures.StartupStoredCapture do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    {:ok,
     %{
       sup: Keyword.fetch!(opts, :sup),
       starter: Keyword.get(opts, :starter, &start_transport/2),
       started: false
     }}
  end

  @impl true
  def handle_call(:ensure, _from, %{started: false} = state) do
    :ok = state.starter.(state.sup, :transport)
    {:reply, :ok, %{state | started: true}}
  end

  def handle_call(:ensure, _from, state), do: {:reply, :ok, state}

  defp start_transport(sup, name) do
    case DynamicSupervisor.start_child(sup, {Agent, fn -> name end}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> raise "could not start the transport: #{inspect(reason)}"
    end
  end
end

# The twin: init/1 runs the capture it takes, so the start_child runs
# inside init/1.
defmodule Argus.Test.Fixtures.StartupCalledCapture do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    sup = Keyword.fetch!(opts, :sup)
    starter = Keyword.get(opts, :starter, &start_transport/2)
    :ok = starter.(sup, :transport)
    {:ok, %{sup: sup}}
  end

  defp start_transport(sup, name) do
    case DynamicSupervisor.start_child(sup, {Agent, fn -> name end}) do
      {:ok, _pid} -> :ok
      {:error, reason} -> raise "could not start the transport: #{inspect(reason)}"
    end
  end
end

# A rest_for_one tree whose later child starts a named transport under
# the earlier DynamicSupervisor, and takes `{:error, {:already_started,
# pid}}` for success: a restarted runtime adopts the transport its last
# incarnation started rather than starting a second.
defmodule Argus.Test.Fixtures.StartupAdoptTransport do
  @moduledoc false
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Fixtures.StartupAdoptRuntime do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.StartupAdoptTransport

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:ensure, _from, state) do
    :ok = start_transport()
    {:reply, :ok, state}
  end

  defp start_transport do
    child = {StartupAdoptTransport, name: StartupAdoptTransport}

    case DynamicSupervisor.start_child(Argus.Test.Fixtures.StartupAdoptRuntimeSup, child) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "could not start the transport: #{inspect(reason)}"
    end
  end
end

defmodule Argus.Test.Fixtures.StartupAdoptTree do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Argus.Test.Fixtures.StartupAdoptRuntimeSup},
      Argus.Test.Fixtures.StartupAdoptRuntime
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

# The twin: the runtime starts an anonymous worker each time, so a
# restarted runtime starts another beside the one left running.
defmodule Argus.Test.Fixtures.StartupDuplicateRuntime do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:ensure, _from, state) do
    {:ok, _pid} =
      DynamicSupervisor.start_child(
        Argus.Test.Fixtures.StartupDuplicateRuntimeSup,
        {Agent, fn -> :transport end}
      )

    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Fixtures.StartupDuplicateTree do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: Argus.Test.Fixtures.StartupDuplicateRuntimeSup},
      Argus.Test.Fixtures.StartupDuplicateRuntime
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

# A keeper that holds what its callers register in its state, under a
# one_for_one supervisor beside three callers that register from init/1.
defmodule Argus.Test.Fixtures.StartupRecoveryKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def register(pid), do: GenServer.call(__MODULE__, {:register, pid})

  @impl true
  def init(registered), do: {:ok, registered}

  @impl true
  def handle_call({:register, pid}, _from, registered),
    do: {:reply, :ok, Map.put(registered, pid, true)}
end

# The caller monitors the keeper and, on its :DOWN, asks itself to
# register again: a restarted keeper is told afresh.
defmodule Argus.Test.Fixtures.StartupRecoveryMonitor do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.StartupRecoveryKeeper

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, register_with_keeper(%{keeper: nil})}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{keeper: ref} = state) do
    send(self(), :register)
    {:noreply, %{state | keeper: nil}}
  end

  def handle_info(:register, state), do: {:noreply, register_with_keeper(state)}

  defp register_with_keeper(state) do
    case Process.whereis(StartupRecoveryKeeper) do
      nil ->
        Process.send_after(self(), :register, 50)
        state

      pid ->
        ref = Process.monitor(pid)
        :ok = StartupRecoveryKeeper.register(self())
        %{state | keeper: ref}
    end
  end
end

# The twin: the caller monitors the keeper too, but on its :DOWN only
# forgets the monitor, and never registers again.
defmodule Argus.Test.Fixtures.StartupRecoveryForgets do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.StartupRecoveryKeeper

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    ref = Process.monitor(StartupRecoveryKeeper)
    :ok = StartupRecoveryKeeper.register(self())
    {:ok, %{keeper: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{keeper: ref} = state),
    do: {:noreply, %{state | keeper: nil}}
end

defmodule Argus.Test.Fixtures.StartupRecoveryTree do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Argus.Test.Fixtures.StartupRecoveryKeeper,
      Argus.Test.Fixtures.StartupRecoveryMonitor,
      Argus.Test.Fixtures.StartupRecoveryForgets
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# A keeper of queued work that, each time it starts, casts its owner
# that it is ready. The owner queued its first batch once, from a timer
# init/1 armed; told of a restart, it queues what is pending again.
defmodule Argus.Test.Fixtures.StartupAnnounceQueue do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def enqueue(items), do: GenServer.cast(__MODULE__, {:enqueue, items})

  @impl true
  def init(queue) do
    send(self(), :announce)
    {:ok, queue}
  end

  @impl true
  def handle_info(:announce, queue) do
    GenServer.cast(Argus.Test.Fixtures.StartupAnnounceOwner, :queue_ready)
    {:noreply, queue}
  end

  @impl true
  def handle_cast({:enqueue, items}, queue), do: {:noreply, items ++ queue}
end

defmodule Argus.Test.Fixtures.StartupAnnounceOwner do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.StartupAnnounceQueue

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :warmed, 100)
    {:ok, %{pending: [:first]}}
  end

  @impl true
  def handle_info(:warmed, state) do
    StartupAnnounceQueue.enqueue(state.pending)
    {:noreply, state}
  end

  def handle_info(:drain, state) do
    StartupAnnounceQueue.enqueue(state.pending)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:queue_ready, state) do
    send(self(), :drain)
    {:noreply, state}
  end
end

# The twin: the keeper announces itself the same way, but the owner
# ignores it, and its first batch is lost with a restarted queue.
defmodule Argus.Test.Fixtures.StartupAnnounceIgnoredQueue do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def enqueue(items), do: GenServer.cast(__MODULE__, {:enqueue, items})

  @impl true
  def init(queue) do
    send(self(), :announce)
    {:ok, queue}
  end

  @impl true
  def handle_info(:announce, queue) do
    GenServer.cast(Argus.Test.Fixtures.StartupAnnounceIgnoredOwner, :queue_ready)
    {:noreply, queue}
  end

  @impl true
  def handle_cast({:enqueue, items}, queue), do: {:noreply, items ++ queue}
end

defmodule Argus.Test.Fixtures.StartupAnnounceIgnoredOwner do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.StartupAnnounceIgnoredQueue

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :warmed, 100)
    {:ok, %{pending: [:first]}}
  end

  @impl true
  def handle_info(:warmed, state) do
    StartupAnnounceIgnoredQueue.enqueue(state.pending)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:queue_ready, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.StartupAnnounceTree do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Argus.Test.Fixtures.StartupAnnounceQueue,
      Argus.Test.Fixtures.StartupAnnounceOwner,
      Argus.Test.Fixtures.StartupAnnounceIgnoredQueue,
      Argus.Test.Fixtures.StartupAnnounceIgnoredOwner
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
