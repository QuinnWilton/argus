# Messages a server is shown to be sent, and has no clause for: the
# witnessed sources `unhandled_info` reads in place of the retired
# "handle_info/2 has no catch-all" (test/soundness/mailbox_test.exs
# asserts each positive; test/analyses/mailbox_unhandled_info_test.exs
# the quiet neighbours).

# ── A monitor's :DOWN: the reason is the runtime's ──────────────────────

defmodule Argus.Test.Soundness.Witness.DownOnlyNormal do
  @moduledoc false
  # Takes its worker's :DOWN only when the worker exits :normal: a crash
  # of the worker is a FunctionClauseError in the server.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state),
    do: {:noreply, Map.delete(state, ref)}
end

defmodule Argus.Test.Soundness.Witness.DownGuardIn do
  @moduledoc false
  # A guard on the reason: :killed and every crash reason fall through.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when reason in [:normal, :shutdown],
      do: {:noreply, Map.delete(state, ref)}
end

defmodule Argus.Test.Soundness.Witness.DownShutdownOnly do
  @moduledoc false
  # A pattern on the reason, in a monitor a helper module takes on the
  # server's stack: `{:shutdown, _}` is one reason of many.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(peer) do
    ref = Argus.Test.Soundness.Witness.Watch.watch(peer)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, {:shutdown, _}}, %{ref: ref} = state),
    do: {:stop, :normal, state}
end

defmodule Argus.Test.Soundness.Witness.Watch do
  @moduledoc false
  def watch(peer), do: Process.monitor(peer)
end

defmodule Argus.Test.Soundness.Witness.PortDownPinned do
  @moduledoc false
  # Monitors a port and pins the ref, but compares the type with
  # :process: the port's :DOWN says :port.
  use GenServer

  def start_link(port), do: GenServer.start_link(__MODULE__, port)

  @impl true
  def init(port) do
    ref = :erlang.monitor(:port, port)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _port, _reason}, %{ref: ref} = state),
    do: {:stop, :normal, state}
end

# Quiet neighbours: the clauses between them take every reason, or the
# clause asks only what the program chose (the ref, the state).

defmodule Argus.Test.Soundness.Witness.DownSplitReasons do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state),
    do: {:noreply, Map.delete(state, ref)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, Map.delete(state, ref)}
end

defmodule Argus.Test.Soundness.Witness.DownReasonInBody do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case reason do
      :normal -> {:noreply, Map.delete(state, ref)}
      _ -> {:stop, reason, state}
    end
  end
end

defmodule Argus.Test.Soundness.Witness.PortDownAnyType do
  @moduledoc false
  use GenServer

  def start_link(port), do: GenServer.start_link(__MODULE__, port)

  @impl true
  def init(port) do
    ref = :erlang.monitor(:port, port)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, _type, _port, _reason}, %{ref: ref} = state),
    do: {:stop, :normal, state}
end

# ── Node events: what :net_kernel.monitor_nodes and monitor_node send ───

defmodule Argus.Test.Soundness.Witness.NodesDownOnly do
  @moduledoc false
  # Watches every node and takes only the :nodedown: the first node to
  # join crashes it.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, MapSet.new()}
  end

  @impl true
  def handle_info({:nodedown, node}, nodes), do: {:noreply, MapSet.delete(nodes, node)}
end

defmodule Argus.Test.Soundness.Witness.NodeWatch do
  @moduledoc false
  def watch(node), do: Node.monitor(node, true)
end

defmodule Argus.Test.Soundness.Witness.NodeDownInHelper do
  @moduledoc false
  # A helper module turns on one node's monitor on the server's stack;
  # handle_info/2 takes only its own tick.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_cast({:follow, node}, state) do
    Argus.Test.Soundness.Witness.NodeWatch.watch(node)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.NodesWithOptions do
  @moduledoc false
  # monitor_nodes/2 with options, from handle_continue/2: the events come
  # as 3-tuples, and no clause names them.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg, {:continue, :watch}}

  @impl true
  def handle_continue(:watch, state) do
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)
    {:noreply, state}
  end

  @impl true
  def handle_info({:peer, _}, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.MonitorNodeCall do
  @moduledoc false
  # :erlang.monitor_node/2 from handle_call/3: {:nodedown, node} has no clause.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_call({:follow, node}, _from, state) do
    true = :erlang.monitor_node(node, true)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.NodesTaken do
  @moduledoc false
  # Quiet: both events have a clause; a node monitor turned off sends nothing.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, MapSet.new()}
  end

  @impl true
  def terminate(_reason, _nodes), do: :net_kernel.monitor_nodes(false)

  @impl true
  def handle_info({:nodeup, node}, nodes), do: {:noreply, MapSet.put(nodes, node)}
  def handle_info({:nodedown, node}, nodes), do: {:noreply, MapSet.delete(nodes, node)}
end

defmodule Argus.Test.Soundness.Witness.NodesOff do
  @moduledoc false
  # Quiet: `false` turns node events off.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    :ok = :net_kernel.monitor_nodes(false)
    {:ok, arg}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

# ── A port's output ────────────────────────────────────────────────────

defmodule Argus.Test.Soundness.Witness.PortExitStatusOnly do
  @moduledoc false
  # Takes the port's exit status and not what it writes before it.
  use GenServer

  def start_link(cmd), do: GenServer.start_link(__MODULE__, cmd)

  @impl true
  def init(cmd) do
    port = Port.open({:spawn, cmd}, [:binary, :exit_status])
    {:ok, %{port: port}}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:exited, status}, state}
end

defmodule Argus.Test.Soundness.Witness.Spawner do
  @moduledoc false
  def spawn_cat, do: :erlang.open_port({:spawn, ~c"cat"}, [:binary])
end

defmodule Argus.Test.Soundness.Witness.PortInHelper do
  @moduledoc false
  # A helper module opens the port on the server's stack; the server takes
  # only the port's :EXIT, pinned to it.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg) do
    Process.flag(:trap_exit, true)
    {:ok, %{port: nil}}
  end

  @impl true
  def handle_cast(:start, state),
    do: {:noreply, %{state | port: Argus.Test.Soundness.Witness.Spawner.spawn_cat()}}

  @impl true
  def handle_info({:EXIT, port, reason}, %{port: port} = state), do: {:stop, reason, state}
end

defmodule Argus.Test.Soundness.Witness.PortFromCall do
  @moduledoc false
  # Opens the port in handle_call/3 and writes to it; handle_info/2 has a
  # clause for another protocol only.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_call({:run, cmd, input}, _from, state) do
    port = Port.open({:spawn, cmd}, [:binary])
    Port.command(port, input)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:result, _}, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.PortReadThere do
  @moduledoc false
  # Quiet: the port's output is read where the port is opened.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_call({:run, cmd}, _from, state) do
    port = Port.open({:spawn, cmd}, [:binary, :exit_status])
    {:reply, collect(port, ""), state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, acc <> data)
      {^port, {:exit_status, _}} -> acc
    end
  end
end

defmodule Argus.Test.Soundness.Witness.PortDataTaken do
  @moduledoc false
  # Quiet: the data clause is pinned to the port the state keeps.
  use GenServer

  def start_link(cmd), do: GenServer.start_link(__MODULE__, cmd)

  @impl true
  def init(cmd), do: {:ok, %{port: Port.open({:spawn, cmd}, [:binary]), out: ""}}

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, %{state | out: state.out <> data}}
end

# ── :erlang.start_timer: `{:timeout, ref, msg}` ──────────────────────────

defmodule Argus.Test.Soundness.Witness.StartTimerMessageClause do
  @moduledoc false
  # Takes the timer's message as if it came bare: the 3-tuple the runtime
  # sends is `{:timeout, ref, :refresh}`, which the `:refresh` clause does
  # not take.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    :erlang.start_timer(1_000, self(), :refresh)
    {:ok, arg}
  end

  @impl true
  def handle_info(:refresh, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.Timers do
  @moduledoc false
  def arm(ms, message), do: :erlang.start_timer(ms, self(), message)
end

defmodule Argus.Test.Soundness.Witness.StartTimerInHelper do
  @moduledoc false
  # A helper module arms the timer on the server's stack.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_cast(:later, state) do
    Argus.Test.Soundness.Witness.Timers.arm(5_000, :flush)
    {:noreply, state}
  end

  @impl true
  def handle_info({:flush, _}, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.StartTimerTwoTuple do
  @moduledoc false
  # A `{:timeout, ref}` clause: the timer's message has three elements.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    ref = :erlang.start_timer(1_000, self(), :expire)
    {:ok, Map.put(arg, :ref, ref)}
  end

  @impl true
  def handle_info({:timeout, ref}, %{ref: ref} = state), do: {:stop, :normal, state}
end

defmodule Argus.Test.Soundness.Witness.StartTimerElsewhere do
  @moduledoc false
  # Quiet: the timer is armed for another process.
  use GenServer

  def start_link(peer), do: GenServer.start_link(__MODULE__, peer)

  @impl true
  def init(peer) do
    :erlang.start_timer(1_000, peer, :wake)
    {:ok, peer}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

# ── An async_nolink task's reply and :DOWN ──────────────────────────────

defmodule Argus.Test.Soundness.Witness.NolinkReplyOnly do
  @moduledoc false
  # Takes the task's reply, flushing its monitor there; a task that
  # crashes sends a :DOWN in its place, and nothing takes it.
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  @impl true
  def init(sup), do: {:ok, %{sup: sup, waiting: %{}}}

  @impl true
  def handle_call({:run, work}, from, state) do
    task = Task.Supervisor.async_nolink(state.sup, work)
    {:noreply, put_in(state.waiting[task.ref], from)}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {from, waiting} = Map.pop(state.waiting, ref)
    GenServer.reply(from, result)
    {:noreply, %{state | waiting: waiting}}
  end
end

defmodule Argus.Test.Soundness.Witness.NolinkDownNormalOnly do
  @moduledoc false
  # A :DOWN clause for the task that ends :normal: a crash's reason
  # falls through.
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  @impl true
  def init(sup), do: {:ok, %{sup: sup}}

  @impl true
  def handle_cast({:run, work}, state) do
    Task.Supervisor.async_nolink(state.sup, work)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.Jobs do
  @moduledoc false
  def run(sup, work), do: Task.Supervisor.async_nolink(sup, work)
end

defmodule Argus.Test.Soundness.Witness.NolinkInHelper do
  @moduledoc false
  # A helper module starts the task on the server's stack.
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  @impl true
  def init(sup), do: {:ok, %{sup: sup}}

  @impl true
  def handle_cast({:run, work}, state) do
    Argus.Test.Soundness.Witness.Jobs.run(state.sup, work)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.NolinkTupleClause do
  @moduledoc false
  # Quiet: an unguarded 2-tuple clause takes the task's reply (the
  # nerves_hub_link SupportScriptsManager shape), and a :DOWN clause for
  # every reason its end.
  use GenServer

  def start_link(sup), do: GenServer.start_link(__MODULE__, sup)

  @impl true
  def init(sup), do: {:ok, %{sup: sup}}

  @impl true
  def handle_cast({:run, work}, state) do
    Task.Supervisor.async_nolink(state.sup, work)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, {result, output}}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, Map.put(state, :last, {result, output})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state),
    do: {:noreply, Map.put(state, :failed, reason)}
end

# ── What a timed receive leaves behind ──────────────────────────────────

defmodule Argus.Test.Soundness.Witness.LateSpawnReply do
  @moduledoc false
  # The vmq_ql_query shape: spawn a worker, wait for its reply by the ref
  # made for it, kill it on the timeout. A reply sent as the timeout fires
  # stays in the mailbox, and handle_info/2 takes only :tick.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(work), do: {:ok, work}

  @impl true
  def handle_info(:tick, work) do
    ref = make_ref()
    parent = self()
    pid = spawn_link(fn -> send(parent, {ref, work.()}) end)

    receive do
      {^ref, _result} -> :ok
    after
      100 ->
        Process.unlink(pid)
        Process.exit(pid, :kill)
    end

    {:noreply, work}
  end
end

defmodule Argus.Test.Soundness.Witness.Probe do
  @moduledoc false
  def probe(target) do
    ref = make_ref()
    parent = self()
    spawn(fn -> send(parent, {ref, :net_adm.ping(target)}) end)

    receive do
      {^ref, answer} -> answer
    after
      1_000 -> :timeout
    end
  end
end

defmodule Argus.Test.Soundness.Witness.LateSpawnInHelper do
  @moduledoc false
  # A helper module spawns and waits on the server's stack; the server
  # takes only its own jobs.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def handle_call({:ping, node}, _from, state),
    do: {:reply, Argus.Test.Soundness.Witness.Probe.probe(node), state}

  @impl true
  def handle_info({:job, _}, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Witness.Waiting do
  @moduledoc false
  # The Connect.wait_for_connection shape: subscribe, wait a while for
  # one event about one subject, and leave.
  def wait_ready(registry, key, pid) do
    {:ok, _} = Registry.register(registry, key, nil)

    receive do
      %{event: "ready", pid: ^pid, conn: conn} -> {:ok, conn}
    after
      5_000 -> {:error, :initializing}
    end
  end
end

defmodule Argus.Test.Soundness.Witness.LateSubscription do
  @moduledoc false
  # A watchdog on whose stack the wait runs: an event broadcast about
  # another pid, or after the wait gave up, reaches a handle_info/2 that
  # takes only its health check.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(%{registry: _, key: _, pid: _} = state), do: {:ok, state}

  @impl true
  def handle_info(:health_check, state) do
    Argus.Test.Soundness.Witness.Waiting.wait_ready(state.registry, state.key, state.pid)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Witness.LateSubscriptionTagged do
  @moduledoc false
  # A :pg group joined and one tagged event waited for, from init/1.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(peer) do
    :ok = :pg.join(:peers, self())

    receive do
      {:ready, ^peer} -> :ok
    after
      1_000 -> :ok
    end

    {:ok, peer}
  end

  @impl true
  def handle_info(:tick, peer), do: {:noreply, peer}
end

defmodule Argus.Test.Soundness.Witness.LateStatem do
  @moduledoc false
  # A gen_statem state spawns and waits; its other state has an :info
  # catch-all, this one does not.
  @behaviour :gen_statem

  def start_link(arg), do: :gen_statem.start_link(__MODULE__, arg, [])

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(work), do: {:ok, :idle, work}

  def idle(:cast, :run, work) do
    ref = make_ref()
    parent = self()
    spawn(fn -> send(parent, {ref, work.()}) end)

    receive do
      {^ref, _} -> {:next_state, :busy, work}
    after
      500 -> {:next_state, :busy, work}
    end
  end

  def busy(:cast, :done, work), do: {:next_state, :idle, work}
  def busy(:info, _msg, _work), do: :keep_state_and_data
end

# Quiet: a wait with no `after`, a clause for a late reply, a catch-all, a
# poll, a timed GenServer.call.

defmodule Argus.Test.Soundness.Witness.SpawnBlockingWait do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(work), do: {:ok, work}

  @impl true
  def handle_call(:run, _from, work) do
    ref = make_ref()
    parent = self()
    spawn_link(fn -> send(parent, {ref, work.()}) end)

    receive do
      {^ref, result} -> {:reply, result, work}
    end
  end

  @impl true
  def handle_info(:tick, work), do: {:noreply, work}
end

defmodule Argus.Test.Soundness.Witness.LateReplyTaken do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(work), do: {:ok, work}

  @impl true
  def handle_call(:run, _from, work) do
    ref = make_ref()
    parent = self()
    spawn(fn -> send(parent, {ref, work.()}) end)

    receive do
      {^ref, result} -> {:reply, result, work}
    after
      100 -> {:reply, :timeout, work}
    end
  end

  @impl true
  def handle_info({ref, _late}, work) when is_reference(ref), do: {:noreply, work}
  def handle_info(:tick, work), do: {:noreply, work}
end

defmodule Argus.Test.Soundness.Witness.LateCatchAll do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(work), do: {:ok, work}

  @impl true
  def handle_call(:run, _from, work) do
    ref = make_ref()
    parent = self()
    spawn(fn -> send(parent, {ref, work.()}) end)

    receive do
      {^ref, result} -> {:reply, result, work}
    after
      100 -> {:reply, :timeout, work}
    end
  end

  @impl true
  def handle_info(_late, work), do: {:noreply, work}
end

defmodule Argus.Test.Soundness.Witness.SpawnPoll do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(work), do: {:ok, work}

  @impl true
  def handle_cast(:flush, work) do
    ref = make_ref()
    spawn(fn -> :ok end)

    receive do
      {^ref, _} -> :ok
    after
      0 -> :ok
    end

    {:noreply, work}
  end

  @impl true
  def handle_info(:tick, work), do: {:noreply, work}
end

# ── A GenStage the program starts is a server like any other ────────────

defmodule Argus.Test.Soundness.Witness.StageTimer do
  @moduledoc false
  # A producer arms a poll for itself and takes only acks.
  use GenStage

  def start_link(arg), do: GenStage.start_link(__MODULE__, arg)

  @impl true
  def init(arg) do
    Process.send_after(self(), :poll, 100)
    {:producer, arg}
  end

  @impl true
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl true
  def handle_info({:ack, _}, state), do: {:noreply, [], state}
end

defmodule Argus.Test.Soundness.Witness.StageMonitor do
  @moduledoc false
  # A producer that monitors its sources and takes a :normal :DOWN alone.
  use GenStage

  def start_link(arg), do: GenStage.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(arg), do: {:producer, arg}

  @impl true
  def handle_call({:source, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, [], state}
  end

  @impl true
  def handle_demand(_demand, state), do: {:noreply, [], state}

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, [], state}
end

defmodule Argus.Test.Soundness.Witness.StageNamed do
  @moduledoc false
  # A named consumer its client API sends :flush to, with no clause for it.
  use GenStage

  def start_link(arg), do: GenStage.start_link(__MODULE__, arg, name: __MODULE__)

  def flush, do: send(__MODULE__, :flush)

  @impl true
  def init(arg), do: {:consumer, arg}

  @impl true
  def handle_events(_events, _from, state), do: {:noreply, [], state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, [], state}
end
