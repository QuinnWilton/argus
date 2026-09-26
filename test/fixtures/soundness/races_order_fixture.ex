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

# ── Handed off: a loader its starter waits for ─────────────────────────

defmodule Argus.Test.Soundness.RacesOrder.Trie do
  # vernemq's vmq_reg_ordered_trie: init/1 spawns a loader that counts
  # every stored topic into the table and, as its last act, reports to
  # its starter. Until the report the server queues the updates it is
  # asked for; the report's clause drains the queue and lets the server
  # serve. The loader's counts and the server's never interleave.
  use GenServer

  @tab :sound_trie

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieHookClient do
  # The program's own client of the server below: the program asks it
  # for updates, and nothing else.
  def subscribed(topic), do: Argus.Test.Soundness.RacesOrder.TrieHookUnused.update(topic, 1)
end

defmodule Argus.Test.Soundness.RacesOrder.TrieHookUnused do
  # The same, with vmq_reg_trie's test hook: a clause that serves an
  # event whatever the status, which nothing in the program asks for. The
  # program is the server's client (TrieHookClient): its requests are all
  # in view.
  use GenServer

  @tab :sound_trie_hook_unused

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:event, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieHookUsed do
  # The test hook, and an API that asks for it: an event the server
  # counts while the loader is still counting.
  use GenServer

  @tab :sound_trie_hook_used

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})
  def event(topic, delta), do: GenServer.call(__MODULE__, {:event, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:event, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieReportEarly do
  # The loader reports before it counts: the server serves while the
  # loader is still at it.
  use GenServer

  @tab :sound_trie_report_early

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      send(me, :loaded)
      Enum.each(stored(), &add/1)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieReportMidway do
  # The loader reports in the middle of its work: what it counts after
  # the report lands among the server's updates.
  use GenServer

  @tab :sound_trie_report_midway

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
      Enum.each(retained(), &add/1)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp retained, do: :persistent_term.get(:sound_trie_retained, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieKeepsWorking do
  # The loader reports, then stays on as a worker that counts what it is
  # sent: its counts race the server's for as long as it lives.
  use GenServer

  @tab :sound_trie_keeps_working

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
      work()
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp work do
    receive do
      {:add, topic} -> add(topic)
    end

    work()
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieUngated do
  # The server serves updates from the start: nothing waits for the
  # report.
  use GenServer

  @tab :sound_trie_ungated

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init}}
  end

  @impl true
  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, s), do: {:noreply, %{s | status: :ready}}

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieOpenedEarly do
  # Another request sets the status the report sets: once it is taken,
  # the server serves while the loader counts.
  use GenServer

  @tab :sound_trie_opened_early

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})
  def force_ready, do: GenServer.call(__MODULE__, :force_ready)

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call(:force_ready, _from, s), do: {:reply, :ok, %{s | status: :ready}}

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieStartsReady do
  # init/1 starts the server ready: the queue clause never matches, and
  # the server serves while the loader counts.
  use GenServer

  @tab :sound_trie_starts_ready

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :ready, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieAnotherReport do
  # Something else sends the report's message: a reload/0 any caller
  # runs opens the gate while the loader counts.
  use GenServer

  @tab :sound_trie_another_report

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})
  def reload, do: send(__MODULE__, :loaded)

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieTimerReport do
  # A timer the server arms sends the report's message too: after a
  # second the server serves, loaded or not.
  use GenServer

  @tab :sound_trie_timer_report

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    Process.send_after(self(), :loaded, 1_000)
    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieReportsToItself do
  # vmq_reg_trie's init_subs loader: its report goes to itself, not to
  # the server, which never waits for it.
  use GenServer

  @tab :sound_trie_reports_to_itself

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(self(), :loaded)
    end)

    {:ok, %{status: :ready, queue: []}}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieReloadLoader do
  # A loader started again on every reload request: the second runs
  # while the server, loaded by the first, serves.
  use GenServer

  @tab :sound_trie_reload_loader

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    load(self())
    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call(:reload, _from, s) do
    load(self())
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp load(me) do
    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieSelfReport do
  # The server sends itself the report's message when it is told to
  # finish early: the gate opens while the loader counts.
  use GenServer

  @tab :sound_trie_self_report

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})
  def finish, do: GenServer.cast(__MODULE__, :finish)

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_cast(:finish, s) do
    send(self(), :loaded)
    {:noreply, s}
  end

  @impl true
  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieWrappedClient do
  # The program's client of TrieWrapped: it hands the server's request
  # helper a message it does not spell.
  def relay(msg), do: Argus.Test.Soundness.RacesOrder.TrieWrapped.request(msg)
end

defmodule Argus.Test.Soundness.RacesOrder.TrieWrapped do
  # The test hook, and a request helper whose callers hand it messages
  # the program does not spell: any of them may be the hook's.
  use GenServer

  @tab :sound_trie_wrapped

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def request(msg), do: GenServer.call(__MODULE__, msg)

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:event, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieReloaderClient do
  # The program's client of the two servers below: it asks for updates,
  # and TrieLiveReloader's client also asks for a reload.
  def subscribed(topic) do
    Argus.Test.Soundness.RacesOrder.TrieDeadReloader.update(topic, 1)
    Argus.Test.Soundness.RacesOrder.TrieLiveReloader.update(topic, 1)
  end

  def reloaded, do: Argus.Test.Soundness.RacesOrder.TrieLiveReloader.reload()
end

defmodule Argus.Test.Soundness.RacesOrder.TrieDeadReloader do
  # vmq_reg_trie's init_subs, which nothing asks for: the clause that
  # starts a second loader, one that reports to nobody, never runs.
  use GenServer

  @tab :sound_trie_dead_reloader

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call(:reload, _from, s) do
    spawn_link(fn -> Enum.each(stored(), &add/1) end)
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieLiveReloader do
  # The same, asked for: vmq_reg_trie's shape, whose init_subscriptions/0
  # asks for it. The second loader counts while the server serves.
  use GenServer

  @tab :sound_trie_live_reloader

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)
  def update(topic, delta), do: GenServer.call(__MODULE__, {:update, topic, delta})
  def reload, do: GenServer.call(__MODULE__, :reload)

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call(:reload, _from, s) do
    spawn_link(fn -> Enum.each(stored(), &add/1) end)
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end

defmodule Argus.Test.Soundness.RacesOrder.TrieNoApi do
  # The test hook on a server whose module offers its users no API: they
  # ask it directly, for anything, the hook included.
  use GenServer

  @tab :sound_trie_no_api

  @impl true
  def init(_o) do
    :ets.new(@tab, [:named_table, :public])
    me = self()

    spawn_link(fn ->
      Enum.each(stored(), &add/1)
      send(me, :loaded)
    end)

    {:ok, %{status: :init, queue: []}}
  end

  @impl true
  def handle_call({:event, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  def handle_call({:update, _, _} = u, _from, %{status: :init, queue: q} = s),
    do: {:reply, :ok, %{s | queue: [u | q]}}

  def handle_call({:update, topic, delta}, _from, s) do
    bump(topic, delta)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:loaded, %{queue: q} = s) do
    Enum.each(Enum.reverse(q), fn {:update, t, d} -> bump(t, d) end)
    {:noreply, %{s | status: :ready, queue: []}}
  end

  defp stored, do: :persistent_term.get(:sound_trie_stored, [])
  defp add(topic), do: bump(topic, 1)

  defp bump(topic, delta) do
    case :ets.lookup(@tab, topic) do
      [{^topic, n}] -> :ets.insert(@tab, {topic, n + delta})
      [] -> :ets.insert(@tab, {topic, delta})
    end
  end
end
