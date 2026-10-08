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
