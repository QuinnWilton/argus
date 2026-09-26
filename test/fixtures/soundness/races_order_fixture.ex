# The races model's ordering programs (docs/design/races.md, "Which
# processes run a function"): a write another process makes is a rival
# only when it can land while the pair's process runs the pair. Each
# ordering the model reads has a quiet program and the nearest real bugs
# it must still report. test/soundness/races_order_test.exs lists them.

# ── Startup order: what a process writes only while it starts ─────────

defmodule Argus.Test.Soundness.RacesOrder.ClusterState do
  # vernemq's vmq_swc_peer_service_manager: the cluster state is one row,
  # seeded by the supervisor's init/1 and merged into by the gossip
  # server once it is up.
  @tab :sound_cluster_state

  def init do
    :ets.new(@tab, [:named_table, :public])
    update_state(MapSet.new([node()]))
  end

  def get_state do
    case :ets.lookup(@tab, :cluster_state) do
      [{:cluster_state, s}] -> s
      [] -> MapSet.new()
    end
  end

  def update_state(s), do: :ets.insert(@tab, {:cluster_state, s})
end

defmodule Argus.Test.Soundness.RacesOrder.ClusterSup do
  # vmq_swc_sup: the state is seeded before the gossip server starts.
  use Supervisor

  alias Argus.Test.Soundness.RacesOrder.{ClusterState, Gossip}

  def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(_o) do
    ClusterState.init()
    Supervisor.init([Gossip], strategy: :one_for_one)
  end
end

defmodule Argus.Test.Soundness.RacesOrder.Gossip do
  # The one writer of the row once the node is up: every merge is its
  # handle_cast's.
  use GenServer

  alias Argus.Test.Soundness.RacesOrder.ClusterState

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def receive_state(peer), do: GenServer.cast(__MODULE__, {:receive_state, peer})

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_cast({:receive_state, peer}, s) do
    ClusterState.update_state(MapSet.union(ClusterState.get_state(), peer))
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.RacesOrder.Peer do
  # A second server that merges into the row once it is up: its merge
  # lands between the gossip server's read and its write.
  use GenServer

  alias Argus.Test.Soundness.RacesOrder.ClusterState

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_info({:joined, node}, s) do
    ClusterState.update_state(MapSet.put(ClusterState.get_state(), node))
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.RacesOrder.Seeder do
  # A worker whose init/1 seeds the row, and whose handle_info seeds it
  # again once it is up: that second seed is a rival.
  use GenServer

  alias Argus.Test.Soundness.RacesOrder.ClusterState

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    ClusterState.update_state(MapSet.new())
    {:ok, o}
  end

  @impl true
  def handle_info(:reseed, s) do
    ClusterState.update_state(MapSet.new())
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.RacesOrder.ClusterSupTask do
  # The supervisor seeds the row from a task its init/1 starts: the task
  # runs whenever it runs, the gossip server's merges included.
  use Supervisor

  alias Argus.Test.Soundness.RacesOrder.{ClusterState, Gossip}

  def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(_o) do
    Task.start(fn -> ClusterState.update_state(MapSet.new([node()])) end)
    Supervisor.init([Gossip], strategy: :one_for_one)
  end
end
