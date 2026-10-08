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
