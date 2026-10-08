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
