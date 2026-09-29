# Adversarial neighbours of each narrowing of the monitor-leak model
# (docs/design/monitor-leaks.md): a shape the narrowing must not excuse,
# which still takes a monitor again before the last one is released.
# test/soundness/monitors_test.exs asserts the finding each must keep.

# ── The run repeats (again_code) ─────────────────────────────────────

defmodule Argus.Test.Soundness.Monitors.SharedByInitAndHandler do
  @moduledoc """
  init/1 and a reconnect handler share the helper that monitors the
  upstream: once code and code that runs again at once. Each reconnect
  takes another monitor on the same registered process.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, connect(%{})}

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, connect(state)}

  defp connect(state) do
    Process.monitor(Process.whereis(:soundness_upstream))
    state
  end
end

defmodule Argus.Test.Soundness.Monitors.StateFunctionMonitor do
  @moduledoc """
  A gen_statem that monitors its caller on every `:watch` call, from a
  state function: an event handler runs again on every event.
  """
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :idle, %{}}

  @impl true
  def handle_event({:call, {pid, _} = from}, :watch, :idle, data) do
    Process.monitor(pid)
    {:keep_state, data, [{:reply, from, :ok}]}
  end
end

defmodule Argus.Test.Soundness.Monitors.HandRolledLoop do
  @moduledoc """
  A spawned receive loop that monitors its peer on every ping and goes
  round again: the loop is code that runs again, whatever started it.
  """
  def start(peer), do: spawn(fn -> loop(peer) end)

  defp loop(peer) do
    receive do
      :ping ->
        Process.monitor(peer)
        loop(peer)

      :stop ->
        :ok
    end
  end
end

# ── The process is one the run can meet again (starts_its_target) ────

defmodule Argus.Test.Soundness.Monitors.StartsThenMonitorsCaller do
  @moduledoc """
  The handler starts a worker, and monitors its caller, not the worker:
  a process the run did not start, met again on the caller's next call.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:run, {pid, _}, state) do
    {:ok, _worker} = Task.start_link(fn -> :ok end)
    Process.monitor(pid)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Soundness.Monitors.StartOrFind do
  @moduledoc """
  A named start that answers the running process when it is already
  started: on that branch the pid is one others hold, monitored again on
  every call.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:join, name}, _from, state) do
    pid =
      case GenServer.start(Argus.Test.Soundness.Monitors.Room, name, name: name) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

    Process.monitor(pid)
    {:reply, {:ok, pid}, state}
  end
end

defmodule Argus.Test.Soundness.Monitors.Room do
  @moduledoc false
  use GenServer

  @impl true
  def init(name), do: {:ok, name}
end

defmodule Argus.Test.Soundness.Monitors.MonitorsStoredWorker do
  @moduledoc """
  The worker is started once, in init/1, and kept in the state; every
  health check monitors it again. The pid the check monitors is not one
  the check started.
  """
  use GenServer

  @impl true
  def init(_) do
    {:ok, worker} = Task.start_link(fn -> Process.sleep(:infinity) end)
    {:ok, %{worker: worker}}
  end

  @impl true
  def handle_info(:check, state) do
    Process.monitor(state.worker)
    {:noreply, state}
  end
end

# ── It can meet T again: a wrapper that answers anything but a start ──
#
# A wrapper's answer is a new process only when every way out of it hands
# back a start's answer (clientlib/answers.dl). Each of these hands back a
# process others hold on some way out, and the monitor piles up there.

defmodule Argus.Test.Soundness.Monitors.Wrappers do
  @moduledoc """
  Wrappers named and shaped like starts that answer a running process on
  one way out: a lookup first, an already-started pid re-wrapped, a
  parameter, a reply.
  """
  def ensure(registry, sup, key) do
    case Registry.lookup(registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(sup, {Argus.Test.Soundness.Monitors.Room, key})
    end
  end

  def start_or_existing(sup, key) do
    case DynamicSupervisor.start_child(sup, {Argus.Test.Soundness.Monitors.Room, key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  def start_unless_running(nil, sup),
    do: DynamicSupervisor.start_child(sup, Argus.Test.Soundness.Monitors.Room)

  def start_unless_running(pid, _sup), do: {:ok, pid}

  def start_session(registry, user), do: GenServer.call(registry, {:session, user})
end

defmodule Argus.Test.Soundness.Monitors.MonitorsLookupWrapper do
  @moduledoc "Monitors what a lookup-first wrapper answers, on every call."
  use GenServer

  alias Argus.Test.Soundness.Monitors.Wrappers

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:join, key}, _from, {registry, sup} = state) do
    {:ok, pid} = Wrappers.ensure(registry, sup, key)
    Process.monitor(pid)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Soundness.Monitors.MonitorsAlreadyStartedWrapper do
  @moduledoc "Monitors what a wrapper answers, the already-started pid re-wrapped as {:ok, pid}."
  use GenServer

  alias Argus.Test.Soundness.Monitors.Wrappers

  @impl true
  def init(sup), do: {:ok, sup}

  @impl true
  def handle_call({:join, key}, _from, sup) do
    {:ok, pid} = Wrappers.start_or_existing(sup, key)
    Process.monitor(pid)
    {:reply, :ok, sup}
  end
end

defmodule Argus.Test.Soundness.Monitors.MonitorsParameterWrapper do
  @moduledoc "Monitors what a wrapper answers, which is its parameter when a pid is passed."
  use GenServer

  alias Argus.Test.Soundness.Monitors.Wrappers

  @impl true
  def init(sup), do: {:ok, sup}

  @impl true
  def handle_call({:join, known}, _from, sup) do
    {:ok, pid} = Wrappers.start_unless_running(known, sup)
    Process.monitor(pid)
    {:reply, :ok, sup}
  end
end

defmodule Argus.Test.Soundness.Monitors.MonitorsReplyWrapper do
  @moduledoc "Monitors what a function named like a start answers: another server's reply."
  use GenServer

  alias Argus.Test.Soundness.Monitors.Wrappers

  @impl true
  def init(registry), do: {:ok, registry}

  @impl true
  def handle_call({:join, user}, _from, registry) do
    {:ok, pid} = Wrappers.start_session(registry, user)
    Process.monitor(pid)
    {:reply, :ok, registry}
  end
end

# ── ended, in a gen_statem: clauses told by type and content ──────────
#
# The record is read by where it is kept (a field), and a clause by its
# event's type and content: a drop in another clause of the same type,
# in another content, still drops it.

defmodule Argus.Test.Soundness.Monitors.StatemUnwatchDrops do
  @moduledoc """
  A cast `{:watch, pid}` monitors and records the subscriber; a cast
  `{:unwatch, pid}` drops it without a demonitor.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :ready, %{subs: %{}}}

  @impl true
  def handle_event(:cast, {:watch, pid}, _state, data),
    do: {:keep_state, %{data | subs: Map.put(data.subs, pid, Process.monitor(pid))}}

  def handle_event(:cast, {:unwatch, pid}, _state, data),
    do: {:keep_state, %{data | subs: Map.delete(data.subs, pid)}}

  def handle_event(:info, {:DOWN, _ref, :process, pid, _}, _state, data),
    do: {:keep_state, %{data | subs: Map.delete(data.subs, pid)}}
end

defmodule Argus.Test.Soundness.Monitors.StatemInternalReset do
  @moduledoc """
  An `:internal` `{:register, pid}` a cast inserts monitors and records
  the process; an `:internal` `:reset` another cast inserts empties the
  record, and the monitors stay.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :ready, %{subs: %{}}}

  @impl true
  def handle_event(:cast, {:register, pid}, _state, _data),
    do: {:keep_state_and_data, [{:next_event, :internal, {:register, pid}}]}

  def handle_event(:cast, :reset, _state, _data),
    do: {:keep_state_and_data, [{:next_event, :internal, :reset}]}

  def handle_event(:internal, {:register, pid}, _state, data),
    do: {:keep_state, %{data | subs: Map.put(data.subs, pid, Process.monitor(pid))}}

  def handle_event(:internal, :reset, _state, data), do: {:keep_state, %{data | subs: %{}}}
end

defmodule Argus.Test.Soundness.Monitors.StatemOtherDownResets do
  @moduledoc """
  The `:DOWN` of the connection's monitor resets every subscriber, whose
  monitors stay (eventstore's AdvisoryLocks, in a gen_statem): a `:DOWN`
  clause's reset of another monitor's record is a drop.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(conn), do: {:ok, :ready, %{conn: Process.monitor(conn), subs: %{}}}

  @impl true
  def handle_event(:cast, {:watch, pid}, _state, data),
    do: {:keep_state, %{data | subs: Map.put(data.subs, pid, Process.monitor(pid))}}

  def handle_event(:info, {:DOWN, ref, :process, _pid, _}, _state, %{conn: ref} = data),
    do: {:keep_state, %{data | subs: %{}}}
end

defmodule Argus.Test.Soundness.Monitors.StateFunctionUnwatch do
  @moduledoc """
  The `{:unwatch, pid}` shape in state functions: a call to `ready/3`
  monitors and records, a cast to it drops without a demonitor.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_), do: {:ok, :ready, %{subs: %{}}}

  def ready({:call, from}, {:watch, pid}, data) do
    subs = Map.put(data.subs, pid, Process.monitor(pid))
    {:keep_state, %{data | subs: subs}, [{:reply, from, :ok}]}
  end

  def ready(:cast, {:unwatch, pid}, data),
    do: {:keep_state, %{data | subs: Map.delete(data.subs, pid)}}
end

# ── ended: the record is where the ref or the pid is kept ─────────────
#
# The neighbours of test/fixtures/monitor_fixture.ex's quiet shapes: the
# same servers, where the field or the table that holds the monitor's ref
# or pid is the one dropped.

defmodule Argus.Test.Soundness.Monitors.ResetsItsRecord do
  @moduledoc "Records each watcher's ref under `subs`; a flush empties `subs` and keeps the monitors."
  use GenServer

  @impl true
  def init(_), do: {:ok, %{subs: %{}, log: []}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    log = [System.monotonic_time() | state.log]
    {:reply, :ok, %{state | subs: Map.put(state.subs, ref, pid), log: log}}
  end

  @impl true
  def handle_cast(:flush, state), do: {:noreply, %{state | subs: %{}}}
end

defmodule Argus.Test.Soundness.Monitors.RemovesFromItsRecord do
  @moduledoc """
  Records each watcher's pid under `subs` (the ref thrown away), and a
  cast removes it from `subs` without a demonitor: the record holds the
  pid, not the ref.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{subs: MapSet.new(), names: %{}}}

  @impl true
  def handle_call({:watch, pid, name}, _from, state) do
    Process.monitor(pid)
    names = Map.put(state.names, name, System.monotonic_time())
    {:reply, :ok, %{state | subs: MapSet.put(state.subs, pid), names: names}}
  end

  @impl true
  def handle_cast({:unwatch, pid}, state),
    do: {:noreply, %{state | subs: MapSet.delete(state.subs, pid), names: state.names}}
end

defmodule Argus.Test.Soundness.Monitors.StatemDropsOwnerMon do
  @moduledoc """
  hackney's shape, where the event that resets the buffers also removes
  the owner's monitor from the map that keeps it, without a demonitor.
  """
  @behaviour :gen_statem

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :connected, %{mons: %{}, buffer: []}}

  @impl true
  def handle_event({:call, from}, {:request, id, stream_to}, :connected, data) do
    mons = Map.put(data.mons, id, Process.monitor(stream_to))
    {:keep_state, %{data | mons: mons, buffer: []}, [{:reply, from, :ok}]}
  end

  def handle_event(:info, {:stream_reset, id}, :connected, data),
    do: {:keep_state, %{data | mons: Map.delete(data.mons, id), buffer: []}}
end

defmodule Argus.Test.Soundness.Monitors.ResetsHelperKeptMap do
  @moduledoc """
  ra's shape, where leadership empties the map `Monitors.add/3` handed
  back (and `monitors` keeps), not a field beside it: every monitor
  stays, and the next registration monitors the process again.
  """
  use GenServer

  alias Argus.Test.Fixtures.MonitorLeak.Monitors

  @impl true
  def init(_), do: {:ok, %{monitors: %{}, notifies: %{}}}

  @impl true
  def handle_call({:register, pid}, _from, state),
    do: {:reply, :ok, %{state | monitors: Monitors.add(pid, :machine, state.monitors)}}

  @impl true
  def handle_cast(:lead, state), do: {:noreply, %{state | monitors: %{}}}
end

defmodule Argus.Test.Soundness.Monitors.Registry do
  @moduledoc false
  # Two layers over the monitor: `register/2` hands back what
  # `Monitors.add/3` answered.
  alias Argus.Test.Fixtures.MonitorLeak.Monitors

  def register(pid, monitors), do: {:ok, Monitors.add(pid, :client, monitors)}
end

defmodule Argus.Test.Soundness.Monitors.ResetsTwoLayersDown do
  @moduledoc """
  The monitor two helpers down, its map taken out of the `{:ok, map}` the
  outer one answers and kept in `clients`; a cast empties `clients`.
  """
  use GenServer

  alias Argus.Test.Soundness.Monitors.Registry

  @impl true
  def init(_), do: {:ok, %{clients: %{}}}

  @impl true
  def handle_call({:register, pid}, _from, state) do
    {:ok, clients} = Registry.register(pid, state.clients)
    {:reply, :ok, %{state | clients: clients}}
  end

  @impl true
  def handle_cast(:reset, state), do: {:noreply, %{state | clients: %{}}}
end

defmodule Argus.Test.Soundness.Monitors.DeletesItsTable do
  @moduledoc """
  Keeps each watcher's ref in `:sound_watchers` and counts watches in
  `:sound_watch_stats`; a cast deletes every watcher row, and the
  monitors stay.
  """
  use GenServer

  @impl true
  def init(_) do
    :ets.new(:sound_watchers, [:named_table, :public])
    :ets.new(:sound_watch_stats, [:named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    :ets.insert(:sound_watchers, {ref, pid})
    :ets.insert(:sound_watch_stats, {:watches, System.monotonic_time()})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    :ets.delete_all_objects(:sound_watchers)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Monitors.FoldResetsChecks do
  @moduledoc """
  global_group's sync, where a cast empties `checks`, the element of the
  fold's answer that holds the refs: every monitor stays, and the next
  sync monitors each peer again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{nodes: %{}, checks: %{}}}

  @impl true
  def handle_call({:sync, peers}, _from, state) do
    {nodes, checks} =
      Enum.reduce(peers, {%{}, %{}}, fn peer, {nodes, checks} ->
        ref = Process.monitor(peer)
        {Map.put(nodes, node(peer), :syncing), Map.put(checks, ref, peer)}
      end)

    {:reply, :ok, %{state | nodes: nodes, checks: checks}}
  end

  @impl true
  def handle_cast(:reset, state), do: {:noreply, %{state | checks: %{}}}
end

# ── ended: the store the run asks ─────────────────────────────────────
#
# The neighbours of the quiet shapes at the end of
# test/fixtures/monitor_fixture.ex (and test/fixtures/erl/mon_asks_pool.erl):
# the store the monitoring run asks is the one dropped, or the ask is not
# about the process or does not gate the monitor.

defmodule Argus.Test.Soundness.Monitors.AsksWatchedDrops do
  @moduledoc """
  Monitors a watcher only where `watched` lacks it; an unwatch removes it
  from `watched` without a demonitor, and the next watch of the same pid
  monitors it again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{watched: MapSet.new(), refs: %{}}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    if MapSet.member?(state.watched, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)

      {:reply, :ok,
       %{state | watched: MapSet.put(state.watched, pid), refs: Map.put(state.refs, ref, pid)}}
    end
  end

  @impl true
  def handle_cast({:unwatch, pid}, state),
    do: {:noreply, %{state | watched: MapSet.delete(state.watched, pid)}}
end

defmodule Argus.Test.Soundness.Monitors.AsksAnotherKey do
  @moduledoc """
  Asks `monitors` about the connection's name, though `monitors` is
  keyed by pid: the ask is never about the process, and every
  registration monitors it again. A checkout removes the pid from
  `conns` without a demonitor.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{conns: %{}, monitors: %{}}}

  @impl true
  def handle_cast({:register, name, pid}, state) do
    monitors =
      if Map.has_key?(state.monitors, name),
        do: state.monitors,
        else: Map.put(state.monitors, pid, Process.monitor(pid))

    {:noreply, %{state | conns: Map.put(state.conns, name, pid), monitors: monitors}}
  end

  @impl true
  def handle_call({:checkout, name}, _from, state),
    do: {:reply, :ok, %{state | conns: Map.delete(state.conns, name)}}
end

defmodule Argus.Test.Soundness.Monitors.AsksAfterMonitoring do
  @moduledoc """
  Monitors first and asks `monitors` after: the ask gates only the write,
  and every registration takes a monitor. A checkout removes the pid from
  `conns` without a demonitor.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{conns: %{}, monitors: %{}}}

  @impl true
  def handle_cast({:register, name, pid}, state) do
    ref = Process.monitor(pid)

    monitors =
      if Map.has_key?(state.monitors, pid),
        do: state.monitors,
        else: Map.put(state.monitors, pid, ref)

    {:noreply, %{state | conns: Map.put(state.conns, name, pid), monitors: monitors}}
  end

  @impl true
  def handle_call({:checkout, name}, _from, state),
    do: {:reply, :ok, %{state | conns: Map.delete(state.conns, name)}}
end

defmodule Argus.Test.Soundness.Monitors.AsksStoreFilledElsewhere do
  @moduledoc """
  Monitors a peer only where `greeted` lacks it, and keeps the ref in
  `refs`; `greeted` is filled by a hello and emptied of a peer by a bye,
  without a demonitor: after the bye, the next watch monitors it again.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{greeted: MapSet.new(), refs: %{}}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    if MapSet.member?(state.greeted, pid) do
      {:reply, :ok, state}
    else
      {:reply, :ok, %{state | refs: Map.put(state.refs, Process.monitor(pid), pid)}}
    end
  end

  @impl true
  def handle_cast({:hello, pid}, state),
    do: {:noreply, %{state | greeted: MapSet.put(state.greeted, pid)}}

  def handle_cast({:bye, pid}, state),
    do: {:noreply, %{state | greeted: MapSet.delete(state.greeted, pid)}}
end

defmodule Argus.Test.Soundness.Monitors.AsksItsTableDrops do
  @moduledoc """
  AsksItsTable's neighbour: the cast deletes the owner's row from
  `:ask_drop_owners`, the table the claim asks, without a demonitor.
  """
  use GenServer

  @impl true
  def init(_) do
    :ets.new(:ask_drop_owners, [:named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:claim, pid}, _from, state) do
    case :ets.lookup(:ask_drop_owners, pid) do
      [] -> :ets.insert(:ask_drop_owners, {pid, Process.monitor(pid)})
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:forget, pid}, state) do
    :ets.delete(:ask_drop_owners, pid)
    {:noreply, state}
  end
end

# ── Released by the run (monitor_released, collected_by_callers) ─────

defmodule Argus.Test.Soundness.Monitors.PlainDemonitor do
  @moduledoc """
  Quiet control: a demonitor without :flush on every way out releases
  the monitor; a :DOWN already queued is the mailbox's to take.
  """
  def ask(pid) do
    ref = Process.monitor(pid)
    send(pid, {:question, self(), ref})

    result =
      receive do
        {:answer, ^ref, a} -> {:ok, a}
        {:DOWN, ^ref, :process, _, reason} -> {:error, reason}
      after
        1000 -> :timeout
      end

    Process.demonitor(ref)
    result
  end
end

defmodule Argus.Test.Soundness.Monitors.DemonitorOnOnePath do
  @moduledoc """
  The answer path demonitors; the timeout path returns with the monitor
  live. One path is not every way out.
  """
  def ask(pid) do
    ref = Process.monitor(pid)
    send(pid, {:question, self(), ref})

    receive do
      {:answer, ^ref, a} ->
        Process.demonitor(ref, [:flush])
        {:ok, a}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, reason}
    after
      1000 -> :timeout
    end
  end
end

defmodule Argus.Test.Soundness.Monitors.DemonitorsAnotherRef do
  @moduledoc """
  Two monitors, and a demonitor of the other one on every way out: the
  one waited on stays live when the wait gives up.
  """
  def ask(pid, other) do
    ref = Process.monitor(pid)
    other_ref = Process.monitor(other)
    send(pid, {:question, self(), ref})

    result =
      receive do
        {:answer, ^ref, a} -> {:ok, a}
        {:DOWN, ^ref, :process, _, reason} -> {:error, reason}
      after
        1000 -> :timeout
      end

    Process.demonitor(other_ref, [:flush])
    result
  end
end

defmodule Argus.Test.Soundness.Monitors.HelperReleasesOnOnePath do
  @moduledoc """
  The ref is handed to a helper that takes its :DOWN, and gives up on a
  timeout without a demonitor: a helper that releases on one way out is
  no release.
  """
  def stop(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    await(ref)
  end

  defp await(ref) do
    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      1000 -> :timeout
    end
  end
end

# ── dropped: nothing asks first (takes_unasked) ──────────────────────

defmodule Argus.Test.Soundness.Monitors.GuardOnRequest do
  @moduledoc """
  The monitor is taken on one arm of a test, but the test reads the
  request, not the state: nothing asks whether the pid is monitored.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, pid, notify?}, _from, state) do
    if notify?, do: Process.monitor(pid)
    {:reply, :ok, state}
  end
end

defmodule Argus.Test.Soundness.Monitors.GuardInOtherClause do
  @moduledoc """
  The call clause asks its state before it monitors; the cast clause
  reaches the same helper without asking.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, MapSet.new()}

  @impl true
  def handle_call({:watch, pid}, _from, watched) do
    if MapSet.member?(watched, pid) do
      {:reply, :ok, watched}
    else
      watch(pid)
      {:reply, :ok, MapSet.put(watched, pid)}
    end
  end

  @impl true
  def handle_cast({:watch, pid}, watched) do
    watch(pid)
    {:noreply, MapSet.put(watched, pid)}
  end

  defp watch(pid) do
    Process.monitor(pid)
    :ok
  end
end

defmodule Argus.Test.Soundness.Monitors.GuardAfterMonitor do
  @moduledoc """
  The state is asked, but after the monitor is taken: the answer changes
  what is recorded, not whether another monitor exists.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    Process.monitor(pid)

    if Map.has_key?(state, pid),
      do: {:reply, :already, state},
      else: {:reply, :ok, Map.put(state, pid, true)}
  end
end

# ── ended: the record is dropped and the monitor kept (dropped_record) ──

defmodule Argus.Test.Soundness.Monitors.DropInHelper do
  @moduledoc """
  Subscribe monitors and records the subscriber under `subs`; unsubscribe
  drops it through a helper, and never demonitors.
  """
  use GenServer

  @impl true
  def init(_), do: {:ok, %{subs: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subs: Map.put(state.subs, pid, ref)}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state), do: {:noreply, forget(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, forget(state, pid)}

  defp forget(state, pid), do: %{state | subs: Map.delete(state.subs, pid)}
end

defmodule Argus.Test.Soundness.Monitors.ResetOnConnectionDown do
  @moduledoc """
  eventstore's AdvisoryLocks shape: the :DOWN of the connection's monitor
  resets every lock, and each owner's monitor stays live; the owner
  locks again after the reconnect and is monitored again.
  """
  use GenServer

  @impl true
  def init(conn), do: {:ok, %{conn: Process.monitor(conn), locks: %{}}}

  @impl true
  def handle_call({:lock, key}, {owner, _}, state) do
    ref = Process.monitor(owner)
    {:reply, :ok, %{state | locks: Map.put(state.locks, ref, key)}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{conn: ref} = state),
    do: {:noreply, %{state | locks: %{}}}

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | locks: Map.delete(state.locks, ref)}}
end

defmodule Argus.Test.Soundness.Monitors.TableDeleteOnCast do
  @moduledoc """
  postgrex#781's Parameters with a named table: insert monitors the
  caller and writes a row; delete removes the row by a cast and never
  demonitors.
  """
  use GenServer

  @impl true
  def init(_) do
    :ets.new(:soundness_params, [:named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:insert, params}, {pid, _}, state) do
    ref = Process.monitor(pid)
    :ets.insert(:soundness_params, {ref, params})
    {:reply, ref, state}
  end

  @impl true
  def handle_cast({:delete, ref}, state) do
    :ets.delete(:soundness_params, ref)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    :ets.delete(:soundness_params, ref)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Monitors.DropAndDemonitor do
  @moduledoc "Quiet control: the unsubscribe clause demonitors the ref it drops."
  use GenServer

  @impl true
  def init(_), do: {:ok, %{subs: %{}}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subs: Map.put(state.subs, pid, ref)}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    {ref, subs} = Map.pop(state.subs, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:noreply, %{state | subs: subs}}
  end
end

defmodule Argus.Test.Soundness.Monitors.WatchOnceAndAgain do
  @moduledoc """
  Watches its peer once, from the handle_continue/2 clause init/1
  continues to, and again on every `:watch` call, through one helper that
  throws the ref away. Only handle_call/3 runs the helper again.
  """
  use GenServer

  @impl true
  def init(peer), do: {:ok, %{peer: peer}, {:continue, :watch}}

  @impl true
  def handle_continue(:watch, state) do
    :ok = watch(state.peer)
    {:noreply, state}
  end

  @impl true
  def handle_call({:watch, pid}, _from, state), do: {:reply, watch(pid), state}

  defp watch(pid) do
    Process.monitor(pid)
    :ok
  end
end

defmodule Argus.Test.Soundness.Monitors.AskOnceAndAgain do
  @moduledoc """
  Asks its peer once, from the handle_continue/2 clause init/1 continues
  to, and again on every `:ask` call, through one helper whose timed wait
  returns with the monitor live. Only handle_call/3 runs the helper again.
  """
  use GenServer

  @impl true
  def init(peer), do: {:ok, %{peer: peer}, {:continue, :ask}}

  @impl true
  def handle_continue(:ask, state) do
    _ = ask(state.peer)
    {:noreply, state}
  end

  @impl true
  def handle_call({:ask, pid}, _from, state), do: {:reply, ask(pid), state}

  defp ask(pid) do
    ref = Process.monitor(pid)
    send(pid, {:question, self(), ref})

    receive do
      {:answer, ^ref, a} ->
        Process.demonitor(ref, [:flush])
        {:ok, a}

      {:DOWN, ^ref, :process, _, reason} ->
        {:error, reason}
    after
      1000 -> :timeout
    end
  end
end
