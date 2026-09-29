defmodule Argus.Test.Fixtures.MonitorLeak do
  @moduledoc """
  Fixtures for the monitor-leak analysis.

  The timeout is the discriminator, so the pairs vary only that: `Leaks` and
  `Blocks` differ by an `after` clause, `Leaks` and `Flushes` by the
  `[:flush]` option.
  """

  defmodule Leaks do
    @moduledoc "The bug: the wait can end without the message, monitor stays live."
    def wait(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
      after
        1000 -> :timeout
      end
    end
  end

  defmodule LogsAfterMonitor do
    @moduledoc """
    Monitors and logs, and hands the ref back: it waits for nothing
    itself. A timed receive the logger's machinery makes on the way (gen's
    call when a handler is removed) is on that machinery's own monitor.
    """
    def watch(pid) do
      ref = Process.monitor(pid)
      :logger.error(~c"watching")
      ref
    end
  end

  defmodule LogsAndLeaks do
    @moduledoc "The same log beside a timed wait of its own: the monitor is live when it gives up."
    def watch(pid) do
      ref = Process.monitor(pid)
      :logger.error(~c"watching")

      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
      after
        1000 -> :timeout
      end
    end
  end

  defmodule InEach do
    @moduledoc "The same leak in a closure Enum.each runs, in the caller's process."
    def wait_all(pids) do
      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :down
        after
          1000 -> :timeout
        end
      end)
    end
  end

  defmodule TaskGivesUp do
    @moduledoc "The leak's wait is the last thing a task does: the monitor ends with the task."
    def start(pid), do: Task.start(fn -> watch(pid) end)

    defp watch(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
      after
        1000 -> :timeout
      end
    end
  end

  defmodule SpawnsWatcher do
    @moduledoc """
    ra's terminate/3: a closure spawned to watch the process die and then
    act, giving up after a grace period. The closure is what the spawn
    runs, and its building function only hands it off: the monitor ends
    with the watcher.
    """
    def watch_then_clean(pid, sup, child) do
      spawn(fn ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, _, _, _} -> Supervisor.terminate_child(sup, child)
        after
          5000 -> :ok
        end
      end)

      :ok
    end
  end

  defmodule TaskPolls do
    @moduledoc "A task that monitors and waits again and again: the stale :DOWN meets the next wait."
    def start(pid), do: Task.start(fn -> poll(pid) end)

    defp poll(pid) do
      Process.monitor(pid)

      receive do
        :stop -> :ok
      after
        1000 -> poll(pid)
      end
    end
  end

  defmodule GraceThenKill do
    @moduledoc """
    Phoenix's Channel.Server.close/2: a grace period for the :DOWN, then a
    kill and a wait for it with no `after`. The monitor is waited out.
    """
    def close(pid, timeout) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        timeout ->
          Process.exit(pid, :kill)
          receive do: ({:DOWN, ^ref, _, _, _} -> :ok)
      end
    end
  end

  defmodule StopsCursor do
    @moduledoc """
    qlc's stop_cursor/1: a look for the cursor's :EXIT with `after 0`,
    and on both branches a wait with no `after` for its :DOWN, which
    pins the process rather than the ref. Every path waits it out.
    """
    def stop(pid) do
      Process.monitor(pid)
      Process.unlink(pid)

      receive do
        {:EXIT, ^pid, _reason} ->
          receive do: ({:DOWN, _, :process, ^pid, _} -> :ok)
      after
        0 ->
          send(pid, {self(), :stop})
          receive do: ({:DOWN, _, :process, ^pid, _} -> :ok)
      end
    end
  end

  defmodule Flushes do
    @moduledoc "Same wait, but the monitor is cancelled and the mailbox cleared."
    def wait(pid) do
      ref = Process.monitor(pid)

      result =
        receive do
          {:DOWN, ^ref, :process, _, _} -> :down
        after
          1000 -> :timeout
        end

      Process.demonitor(ref, [:flush])
      result
    end
  end

  defmodule Blocks do
    @moduledoc """
    No `after`, so the receive consumes either the reply or the {:DOWN, ...}
    and the monitor cannot outlive the wait.
    """
    def wait(pid) do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
        {:reply, ^ref, value} -> value
      end
    end
  end

  defmodule NoMonitor do
    @moduledoc "A timed receive with no monitor has nothing to leak."
    def wait do
      receive do
        :ok -> :ok
      after
        1000 -> :timeout
      end
    end
  end

  defmodule LeaksThroughHelper do
    @moduledoc "The Finch shape: monitor in the entry, timed wait in a private loop."
    def request(pid) do
      ref = Process.monitor(pid)
      wait_loop(ref)
    end

    defp wait_loop(ref) do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
        {:chunk, ^ref} -> wait_loop(ref)
      after
        1000 -> :timeout
      end
    end
  end

  defmodule FlushesInHelper do
    @moduledoc "Same shape, but the helper cancels the monitor on its way out."
    def request(pid) do
      ref = Process.monitor(pid)
      wait_loop(ref)
    end

    defp wait_loop(ref) do
      receive do
        {:DOWN, ^ref, :process, _, _} -> :down
      after
        1000 ->
          Process.demonitor(ref, [:flush])
          :timeout
      end
    end
  end

  defmodule CollectedByCaller do
    @moduledoc """
    GenStage's ConsumerSupervisor shutdown, after OTP's old supervisor:
    `monitor_child/1` monitors, looks once (`after 0`) for an exit already
    queued, and returns with the monitor live; its caller then waits for
    every child's :DOWN.
    """
    def terminate_children(pids) do
      monitored = monitor_children(pids)
      Enum.each(Map.keys(monitored), &Process.exit(&1, :shutdown))
      wait_children(monitored, map_size(monitored))
    end

    defp monitor_children(pids) do
      Enum.reduce(pids, %{}, fn pid, acc ->
        case monitor_child(pid) do
          :ok -> Map.put(acc, pid, true)
          {:error, _reason} -> acc
        end
      end)
    end

    defp monitor_child(pid) do
      ref = Process.monitor(pid)
      Process.unlink(pid)

      receive do
        {:EXIT, ^pid, reason} ->
          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> {:error, reason}
          end
      after
        0 -> :ok
      end
    end

    defp wait_children(_pids, 0), do: :ok

    defp wait_children(pids, size) do
      receive do
        {:DOWN, _ref, :process, pid, _reason} -> wait_children(Map.delete(pids, pid), size - 1)
      end
    end
  end

  defmodule ReturnsLive do
    @moduledoc "The same monitor_child/1, whose caller never waits: the monitors outlive the look."
    def unlink_all(pids), do: Enum.filter(pids, &(monitor_child(&1) == :ok))

    defp monitor_child(pid) do
      ref = Process.monitor(pid)
      Process.unlink(pid)

      receive do
        {:EXIT, ^pid, reason} ->
          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> {:error, reason}
          end
      after
        0 -> :ok
      end
    end
  end

  defmodule WaitsOnOnePath do
    @moduledoc "The caller waits only when asked to: on the other path the monitors stay live."
    def stop_children(pids, wait?) do
      monitored = Enum.filter(pids, &(monitor_child(&1) == :ok))

      if wait? do
        Enum.each(monitored, &Process.exit(&1, :shutdown))
        wait_children(length(monitored))
      else
        :ok
      end
    end

    defp monitor_child(pid) do
      Process.monitor(pid)

      receive do
        {:EXIT, ^pid, _reason} -> :exited
      after
        0 -> :ok
      end
    end

    defp wait_children(0), do: :ok

    defp wait_children(n) do
      receive do
        {:DOWN, _ref, :process, _pid, _reason} -> wait_children(n - 1)
      end
    end
  end

  defmodule CollectedOnOneCaller do
    @moduledoc "One caller waits for the :DOWN, another does not: the second leaves it live."
    def stop(pid) do
      :ok = monitor_child(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, _ref, :process, ^pid, _reason} -> :ok
      end
    end

    def check(pid), do: monitor_child(pid)

    defp monitor_child(pid) do
      Process.monitor(pid)

      receive do
        {:EXIT, ^pid, _reason} -> :exited
      after
        0 -> :ok
      end
    end
  end

  defmodule CollectedByRef do
    @moduledoc "The ref goes back to the caller, whose wait pins it."
    def stop(pid) do
      ref = monitor_and_signal(pid)

      receive do
        {:DOWN, ^ref, :process, _, reason} -> reason
      end
    end

    defp monitor_and_signal(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:stopping, ^pid} -> :ok
      after
        0 -> :ok
      end

      ref
    end
  end

  defmodule FlushedByCaller do
    @moduledoc "The ref goes back to the caller, which demonitors it with :flush."
    def ping(pid) do
      ref = monitor_and_signal(pid)
      Process.demonitor(ref, [:flush])
      :ok
    end

    defp monitor_and_signal(pid) do
      ref = Process.monitor(pid)
      send(pid, :ping)

      receive do
        {:pong, ^pid} -> :ok
      after
        0 -> :ok
      end

      ref
    end
  end

  defmodule WaitsForAnotherRef do
    @moduledoc "The caller waits for the :DOWN of a monitor of its own, not the one it was handed."
    def stop(pid, other) do
      _ref = monitor_and_signal(pid)
      ref = Process.monitor(other)

      receive do
        {:DOWN, ^ref, :process, _, reason} -> reason
      end
    end

    defp monitor_and_signal(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:stopping, ^pid} -> :ok
      after
        0 -> :ok
      end

      ref
    end
  end

  defmodule NeverReleases do
    @moduledoc """
    The Postgrex.Parameters shape: monitors on insert, deletes the entry on
    an explicit path, demonitors nowhere.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:insert, value}, {pid, _}, state) do
      ref = Process.monitor(pid)
      {:reply, ref, Map.put(state, ref, value)}
    end

    @impl true
    def handle_cast({:delete, ref}, state), do: {:noreply, Map.delete(state, ref)}

    @impl true
    def handle_info({:DOWN, ref, :process, _, _}, state), do: {:noreply, Map.delete(state, ref)}
  end

  defmodule ReleasesOnDelete do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:insert, value}, {pid, _}, state) do
      ref = Process.monitor(pid)
      {:reply, ref, Map.put(state, ref, value)}
    end

    @impl true
    def handle_cast({:delete, ref}, state) do
      Process.demonitor(ref, [:flush])
      {:noreply, Map.delete(state, ref)}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, _}, state), do: {:noreply, Map.delete(state, ref)}
  end

  defmodule KillsMonitored do
    @moduledoc "Terminates a child it monitors; the :DOWN lands in the crash clause."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(sup), do: {:ok, %{sup: sup, running: %{}}}

    @impl true
    def handle_call({:track, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.running[ref], pid)}
    end

    @impl true
    def handle_cast({:kill, pid}, state) do
      DynamicSupervisor.terminate_child(state.sup, pid)
      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, reason}, state) do
      {_, state} = pop_in(state.running[ref])
      {:noreply, Map.put(state, :last_crash, reason)}
    end
  end

  defmodule KillsMonitoredAside do
    @moduledoc """
    KillsMonitored with the stop made in a process the server spawns: the
    server still monitors the child, and the :DOWN of the death it caused
    still lands in its crash clause. A monitor the spawned process took
    would be that process's; this one is the server's.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{running: %{}}}

    @impl true
    def handle_call({:track, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.running[ref], pid)}
    end

    @impl true
    def handle_cast({:kill, pid}, state) do
      spawn(fn -> GenServer.stop(pid, :normal, 5_000) end)
      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, reason}, state) do
      {_, state} = pop_in(state.running[ref])
      {:noreply, Map.put(state, :last_crash, reason)}
    end
  end

  defmodule ClientSideMonitor do
    @moduledoc """
    A GenServer module whose only monitor is in a client API function: it
    runs in the caller's process, so the server has nothing to release.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def request(server, msg) do
      ref = Process.monitor(server)
      GenServer.cast(server, {msg, self(), ref})

      receive do
        {^ref, reply} -> reply
        {:DOWN, ^ref, _, _, reason} -> {:error, reason}
      end
    end

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_cast({_msg, from, ref}, state) do
      send(from, {ref, :ok})
      {:noreply, Map.delete(state, ref)}
    end
  end

  defmodule DropsRef do
    @moduledoc "The Phoenix PubSub Local shape: monitor every subscriber, keep nothing."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:subscribe, pid}, _from, state) do
      Process.monitor(pid)
      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, Map.delete(state, pid)}
  end

  # A monitor made as a tail call returns its ref to the caller: kept
  # where the caller keeps it, lost where the caller throws it away.

  defmodule MapsRefs do
    @moduledoc "exq's WorkerDrainer: a ref per worker, mapped into a set and awaited."
    use GenServer

    @impl true
    def init(_), do: {:ok, MapSet.new()}

    @impl true
    def handle_call({:drain, pids}, _from, refs) do
      new = pids |> Enum.map(fn pid -> Process.monitor(pid) end) |> MapSet.new()
      {:reply, :ok, MapSet.union(refs, new)}
    end

    # The :DOWN is counted, not removed: a removal elsewhere is
    # never_released's question, not this one's.
    @impl true
    def handle_info({:DOWN, _ref, :process, _, _}, refs), do: {:noreply, refs}
  end

  defmodule EachDropsRefs do
    @moduledoc "ejabberd's router init: every pid monitored in a foreach, every ref gone."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:watch, pids}, _from, state) do
      Enum.each(pids, fn pid -> Process.monitor(pid) end)
      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, Map.delete(state, pid)}
  end

  defmodule ForeachDropsRefs do
    @moduledoc "The Erlang order: the fun is built, the list read, then lists:foreach runs."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:watch, pids}, _from, state) do
      :lists.foreach(fn pid -> Process.monitor(pid) end, Enum.filter(pids, &is_pid/1))
      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, Map.delete(state, pid)}
  end

  defmodule HelperKeepsRef do
    @moduledoc "A helper that returns the ref; its one caller keeps it."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:watch, pid}, _from, state) do
      ref = watch(pid)
      {:reply, :ok, Map.put(state, ref, pid)}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _, _}, state), do: {:noreply, state}

    defp watch(pid), do: Process.monitor(pid)
  end

  defmodule HelperDropsRef do
    @moduledoc "A helper that returns the ref; its one caller throws it away."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:watch, pid}, _from, state) do
      watch(pid)
      {:reply, :ok, Map.put(state, pid, true)}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, Map.delete(state, pid)}

    defp watch(pid), do: Process.monitor(pid)
  end

  # terminate/2 is the last callback: what it leaves live ends with the
  # process a moment later. The same drain run from handle_call/3 is not.

  defmodule DrainsOnTerminate do
    @moduledoc "exq's WorkerDrainer: monitor every worker on the way out, wait a grace period."
    use GenServer

    @impl true
    def init(pids) do
      Process.flag(:trap_exit, true)
      {:ok, pids}
    end

    @impl true
    def terminate(_reason, pids), do: drain(pids)

    def drain(pids) do
      pids |> Enum.map(fn pid -> Process.monitor(pid) end) |> MapSet.new() |> await()
    end

    def await(refs) do
      if MapSet.size(refs) == 0 do
        :ok
      else
        receive do
          {:DOWN, ref, _, _, _} -> refs |> MapSet.delete(ref) |> await()
        after
          5_000 -> :ok
        end
      end
    end
  end

  defmodule DrainsOnCall do
    @moduledoc "The same drain, also run from handle_call/3: the server lives on."
    use GenServer

    @impl true
    def init(pids) do
      Process.flag(:trap_exit, true)
      {:ok, pids}
    end

    @impl true
    def handle_call(:drain, _from, pids), do: {:reply, drain(pids), pids}

    @impl true
    def terminate(_reason, pids), do: drain(pids)

    def drain(pids) do
      pids |> Enum.map(fn pid -> Process.monitor(pid) end) |> MapSet.new() |> await()
    end

    def await(refs) do
      if MapSet.size(refs) == 0 do
        :ok
      else
        receive do
          {:DOWN, ref, _, _, _} -> refs |> MapSet.delete(ref) |> await()
        after
          5_000 -> :ok
        end
      end
    end
  end

  # OTP's old supervisor shutdown, as rabbit's supervisor2 and brod's
  # brod_supervisor3 copy it: monitor_child/1 drops the ref and returns
  # {:error, reason} having collected the :DOWN, or :ok with it live; the
  # caller waits for the :DOWN by pid on the :ok side, first with a
  # grace period, then after a kill.

  defmodule ForkShutdown do
    @moduledoc false
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:stop_child, pid}, _from, state), do: {:reply, shutdown(pid, 5_000), state}

    defp shutdown(pid, time) do
      case monitor_child(pid) do
        :ok ->
          Process.exit(pid, :shutdown)

          receive do
            {:DOWN, _ref, :process, ^pid, :shutdown} -> :ok
            {:DOWN, _ref, :process, ^pid, other} -> {:error, other}
          after
            time ->
              Process.exit(pid, :kill)

              receive do
                {:DOWN, _ref, :process, ^pid, other} -> {:error, other}
              end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp monitor_child(pid) do
      Process.monitor(pid)
      Process.unlink(pid)

      receive do
        {:EXIT, ^pid, reason} ->
          receive do
            {:DOWN, _ref, :process, ^pid, _} -> {:error, reason}
          end
      after
        0 -> :ok
      end
    end
  end

  defmodule ForkShutdownForgets do
    @moduledoc "The same monitor_child, but the caller's :ok side never waits for the :DOWN."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:stop_child, pid}, _from, state) do
      case monitor_child(pid) do
        :ok ->
          Process.exit(pid, :shutdown)
          {:reply, :ok, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end

    defp monitor_child(pid) do
      Process.monitor(pid)
      Process.unlink(pid)

      receive do
        {:EXIT, ^pid, reason} ->
          receive do
            {:DOWN, _ref, :process, ^pid, _} -> {:error, reason}
          end
      after
        0 -> :ok
      end
    end
  end

  # A server that starts a worker and monitors it keeps nothing it needs
  # in the ref: the worker's :DOWN ends the relationship. Not when the
  # pid goes to someone else.

  defmodule MonitorsOwnWorker do
    @moduledoc "exq's worker: start the job's task, monitor it, keep its pid."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_cast({:run, job}, state) do
      {:ok, pid} = Task.start_link(fn -> job.() end)
      Process.monitor(pid)
      {:noreply, Map.put(state, pid, job)}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, Map.delete(state, pid)}
  end

  defmodule MonitorsHandedWorker do
    @moduledoc "The same start, but the pid is cast to a registry: it may have another owner."
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_cast({:run, job, registry}, state) do
      {:ok, pid} = Task.start_link(fn -> job.() end)
      Process.monitor(pid)
      GenServer.cast(registry, {:register, pid})
      {:noreply, Map.put(state, pid, job)}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, Map.delete(state, pid)}
  end

  # A process a start answered through the program's own functions is as
  # new as one the monitoring function starts itself (issue #3, Tortoise's
  # connection): a wrapper that hands back the start's answer on every way
  # out, however many layers and in whichever module.

  defmodule Transmitters do
    @moduledoc """
    Tortoise's TransmitterSupervisor: a DynamicSupervisor whose
    `start_transmitter/2` (with its default-argument `start_transmitter/1`)
    hands back `DynamicSupervisor.start_child/2`'s answer.
    """
    use DynamicSupervisor

    def start_link(arg), do: DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)

    def start_transmitter(sup \\ __MODULE__, opts) do
      opts = Keyword.put(opts, :parent, self())

      spec =
        {Argus.Test.Fixtures.MonitorLeak.Transmitter, Keyword.take(opts, [:transport, :parent])}

      DynamicSupervisor.start_child(sup, spec)
    end

    @impl true
    def init(_arg), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule Transmitter do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule ConnectsThroughWrapper do
    @moduledoc """
    Tortoise's Connection (issue #3): each `:connect` starts a transmitter
    through `Transmitters.start_transmitter/1`, monitors it and keeps `{pid,
    ref}`; the `:DOWN` of that pid and ref clears it and connects again,
    and other `:internal` clauses reset fields of their own. One monitor per
    transmitter, which its `:DOWN` ends.
    """
    @behaviour :gen_statem

    def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(opts) do
      data = %{opts: opts, receiver: nil, pending: %{}, backoff: 0}
      {:ok, :connecting, data, [{:next_event, :internal, :connect}]}
    end

    @impl true
    def handle_event(:info, {:incoming, package}, _state, _data) when is_binary(package),
      do: {:keep_state_and_data, [{:next_event, :internal, {:received, package}}]}

    def handle_event(:internal, {:received, _package}, :connected, data),
      do: {:keep_state, %{data | pending: %{}}}

    def handle_event(:internal, :connect, :connecting, data) do
      transport = Keyword.get(data.opts, :transport)

      {:ok, t_pid} =
        Argus.Test.Fixtures.MonitorLeak.Transmitters.start_transmitter(
          parent: self(),
          transport: transport
        )

      data = %{data | receiver: {t_pid, Process.monitor(t_pid)}}
      {timeout, data} = Map.get_and_update(data, :backoff, &{&1, &1 + 1})
      {:keep_state, data, [{:state_timeout, timeout, :attempt_connection}]}
    end

    def handle_event(:state_timeout, :attempt_connection, :connecting, data),
      do: {:next_state, :connected, data}

    def handle_event(
          :info,
          {:DOWN, receiver_ref, :process, receiver_pid, _reason},
          state,
          %{receiver: {receiver_pid, receiver_ref}} = data
        )
        when state in [:connected, :connecting] do
      {:next_state, :connecting, %{data | receiver: nil}, [{:next_event, :internal, :connect}]}
    end
  end

  defmodule StartsThroughLocalWrapper do
    @moduledoc """
    A private wrapper that tail-calls a start, and a server that monitors
    what it answers and throws the ref away: the process is new on every run.
    """
    use GenServer

    @impl true
    def init(sup), do: {:ok, sup}

    @impl true
    def handle_call(:work, _from, sup) do
      {:ok, pid} = start_worker(sup)
      Process.monitor(pid)
      {:reply, :ok, sup}
    end

    defp start_worker(sup),
      do: DynamicSupervisor.start_child(sup, Argus.Test.Fixtures.MonitorLeak.Transmitter)
  end

  defmodule Starters do
    @moduledoc """
    Wrappers that pass a start's answer on: through a `case` that rebuilds
    `{:ok, pid}` and `{:error, reason}`, one layer over another, and one
    that hands back the bare pid.
    """
    def start_passing(sup) do
      case start_raw(sup) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end

    def start_bare(arg) do
      {:ok, pid} = GenServer.start_link(Argus.Test.Fixtures.MonitorLeak.Transmitter, arg)
      pid
    end

    defp start_raw(sup),
      do: DynamicSupervisor.start_child(sup, Argus.Test.Fixtures.MonitorLeak.Transmitter)
  end

  defmodule StartsThroughLayers do
    @moduledoc """
    Monitors what two layers of another module's wrappers answered, and a
    bare pid a third hands back: both new on every run.
    """
    use GenServer

    alias Argus.Test.Fixtures.MonitorLeak.Starters

    @impl true
    def init(sup), do: {:ok, sup}

    @impl true
    def handle_call(:work, _from, sup) do
      {:ok, pid} = Starters.start_passing(sup)
      Process.monitor(pid)
      {:reply, :ok, sup}
    end

    def handle_call(:bare, _from, sup) do
      pid = Starters.start_bare(sup)
      Process.monitor(pid)
      {:reply, :ok, sup}
    end
  end

  # A gen_statem's clauses are picked by the event's type and content
  # together (issue #3): what one `:internal` clause records is not what
  # another `:internal` clause resets, and an `:info` clause whose content
  # is `:DOWN` is a :DOWN clause.

  defmodule StatemReceiverFromOpts do
    @moduledoc """
    Monitors the receiver its options name on each `:connect` and keeps
    `{pid, ref}`; another `:internal` clause resets the pending map, and
    the receiver's own `:DOWN` clears it. Nothing drops the receiver
    while it lives.
    """
    @behaviour :gen_statem

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(opts),
      do:
        {:ok, :connecting, %{opts: opts, receiver: nil, pending: %{}},
         [{:next_event, :internal, :connect}]}

    @impl true
    def handle_event(:internal, :connect, :connecting, data) do
      pid = Keyword.fetch!(data.opts, :receiver)
      {:keep_state, %{data | receiver: {pid, Process.monitor(pid)}}}
    end

    def handle_event(:internal, {:received, _package}, _state, data),
      do: {:keep_state, %{data | pending: %{}}}

    def handle_event(:info, {:incoming, package}, _state, _data),
      do: {:keep_state_and_data, [{:next_event, :internal, {:received, package}}]}

    def handle_event(
          :info,
          {:DOWN, ref, :process, pid, _},
          _state,
          %{receiver: {pid, ref}} = data
        ),
        do:
          {:next_state, :connecting, %{data | receiver: nil},
           [{:next_event, :internal, :connect}]}
  end

  defmodule StatemForgetsOnDown do
    @moduledoc """
    Watches each subscriber a cast names and forgets it in its `:DOWN`
    clause: the removal is that monitor's own end.
    """
    @behaviour :gen_statem

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(_), do: {:ok, :ready, %{subs: %{}}}

    @impl true
    def handle_event(:cast, {:watch, pid}, _state, data),
      do: {:keep_state, %{data | subs: Map.put(data.subs, pid, Process.monitor(pid))}}

    def handle_event(:info, {:DOWN, _ref, :process, pid, _}, _state, data),
      do: {:keep_state, %{data | subs: Map.delete(data.subs, pid)}}
  end

  # The record a monitor leaves is the field (or table) that holds its ref
  # or its pid, not every field the monitoring clause returns: a reset of
  # another field is no drop of it. Each is quiet; its neighbour in
  # test/fixtures/soundness/monitors_fixture.ex drops the record itself.

  defmodule ResetsAnotherField do
    @moduledoc """
    Records each watcher's ref under `subs`, and logs when requests came
    in `log`; a flush empties the log. The watcher's own `:DOWN` forgets
    it.
    """
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
    def handle_cast(:flush, state), do: {:noreply, %{state | log: []}}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _}, state),
      do: {:noreply, %{state | subs: Map.delete(state.subs, ref)}}
  end

  defmodule RemovesFromAnotherField do
    @moduledoc """
    Records each watcher's ref under `subs`, and when each name was last
    asked for under `names`; a cast removes an entry from `names`, and
    returns `subs` as it was.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{subs: %{}, names: %{}}}

    @impl true
    def handle_call({:watch, pid, name}, _from, state) do
      ref = Process.monitor(pid)
      names = Map.put(state.names, name, System.monotonic_time())
      {:reply, :ok, %{state | subs: Map.put(state.subs, ref, pid), names: names}}
    end

    @impl true
    def handle_cast({:rename, name}, state),
      do: {:noreply, %{state | names: Map.delete(state.names, name), subs: state.subs}}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _}, state),
      do: {:noreply, %{state | subs: Map.delete(state.subs, ref)}}
  end

  defmodule OwnerBesideBuffers do
    @moduledoc """
    hackney's connection: a request monitors the process it streams to and
    keeps it and the ref in `owner` and `owner_mon`; other events reset
    the stream buffers. The owner's `:DOWN` ends the connection.
    """
    @behaviour :gen_statem

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(owner),
      do: {:ok, :connected, %{owner: owner, owner_mon: nil, streams: %{}, buffer: []}}

    @impl true
    def handle_event({:call, from}, {:request, stream_to}, :connected, data) do
      data = %{data | owner: stream_to, owner_mon: Process.monitor(stream_to), buffer: []}
      {:keep_state, data, [{:reply, from, :ok}]}
    end

    def handle_event(:info, {:stream_reset, id}, :connected, data),
      do: {:keep_state, %{data | streams: Map.delete(data.streams, id), buffer: []}}

    def handle_event(:info, {:DOWN, ref, :process, _pid, _}, _state, %{owner_mon: ref} = data),
      do: {:stop, :normal, data}
  end

  defmodule Monitors do
    @moduledoc """
    ra's `ra_monitors`: `add/3` monitors a process once and hands back the
    map that keeps it; `remove/2` demonitors.
    """
    def add(pid, component, monitors) do
      case monitors do
        %{^pid => {ref, components}} ->
          Map.put(monitors, pid, {ref, Map.put(components, component, :ok)})

        _ ->
          Map.put(monitors, pid, {Process.monitor(pid), %{component => :ok}})
      end
    end

    def remove(pid, monitors) do
      case Map.pop(monitors, pid) do
        {{ref, _components}, rest} ->
          Process.demonitor(ref)
          rest

        {nil, rest} ->
          rest
      end
    end
  end

  defmodule KeepsMonitorsResetsNotifies do
    @moduledoc """
    ra's server: registers a process through `Monitors.add/3` and keeps
    the map in `monitors`, beside the notifications it owes in
    `notifies`; entering leadership empties `notifies`, and `unregister`
    goes through `Monitors.remove/2`.
    """
    use GenServer

    alias Argus.Test.Fixtures.MonitorLeak.Monitors

    @impl true
    def init(_), do: {:ok, %{monitors: %{}, notifies: %{}}}

    @impl true
    def handle_call({:register, pid, correlation}, _from, state) do
      monitors = Monitors.add(pid, :machine, state.monitors)
      notifies = Map.put(state.notifies, correlation, [])
      {:reply, :ok, %{state | monitors: monitors, notifies: notifies}}
    end

    def handle_call({:unregister, pid}, _from, state),
      do: {:reply, :ok, %{state | monitors: Monitors.remove(pid, state.monitors)}}

    @impl true
    def handle_cast(:lead, state), do: {:noreply, %{state | notifies: %{}}}

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state),
      do: {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
  end

  defmodule WritesAnotherTable do
    @moduledoc """
    Keeps each watcher's ref in `:watchers_by_ref` and counts watches in
    `:watch_stats`; a cast clears the stats. The watcher's own `:DOWN`
    deletes its row.
    """
    use GenServer

    @impl true
    def init(_) do
      :ets.new(:watchers_by_ref, [:named_table, :public])
      :ets.new(:watch_stats, [:named_table, :public])
      {:ok, nil}
    end

    @impl true
    def handle_call({:watch, pid}, _from, state) do
      ref = Process.monitor(pid)
      :ets.insert(:watchers_by_ref, {ref, pid})
      :ets.insert(:watch_stats, {:watches, System.monotonic_time()})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast(:reset_stats, state) do
      :ets.delete_all_objects(:watch_stats)
      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _}, state) do
      :ets.delete(:watchers_by_ref, ref)
      {:noreply, state}
    end
  end

  defmodule KeepsAnotherPieceOfTheMessage do
    @moduledoc """
    Monitors the pid a request names and keeps its ref in `subs`; the
    request's `name` goes to `names`, which a cast prunes. The pid's
    record is `subs`, not a field made of another piece of the message.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{subs: %{}, names: []}}

    @impl true
    def handle_call({:watch, pid, name}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subs: Map.put(state.subs, ref, pid), names: [name | state.names]}}
    end

    @impl true
    def handle_cast({:forget, name}, state),
      do: {:noreply, %{state | names: List.delete(state.names, name)}}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _}, state),
      do: {:noreply, %{state | subs: Map.delete(state.subs, ref)}}
  end

  defmodule FoldKeepsNodesAndChecks do
    @moduledoc """
    global_group's sync: a fold monitors each peer and answers `{nodes,
    checks}`, the refs in `checks`; a cast empties `nodes`, which holds
    no monitor. Each peer's `:DOWN` forgets its check.
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
    def handle_cast(:forget_nodes, state), do: {:noreply, %{state | nodes: %{}}}

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _}, state),
      do: {:noreply, %{state | checks: Map.delete(state.checks, ref)}}
  end

  # What lets a monitor be taken again is the store its run asks before it
  # monitors, when it asks one. Each is quiet; its neighbour in
  # test/fixtures/soundness/monitors_fixture.ex drops the store asked.

  defmodule AsksWatched do
    @moduledoc """
    Monitors a watcher only where `watched` lacks it, keeping the ref in
    `refs` and the pid in `watched` and under its name in `names`; a
    rename removes the name and keeps the monitor. The next watch of the
    same pid finds it in `watched`.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{watched: MapSet.new(), refs: %{}, names: %{}}}

    @impl true
    def handle_call({:watch, name, pid}, _from, state) do
      state =
        if MapSet.member?(state.watched, pid) do
          state
        else
          ref = Process.monitor(pid)
          %{state | watched: MapSet.put(state.watched, pid), refs: Map.put(state.refs, ref, pid)}
        end

      {:reply, :ok, %{state | names: Map.put(state.names, name, pid)}}
    end

    @impl true
    def handle_cast({:rename, name}, state),
      do: {:noreply, %{state | names: Map.delete(state.names, name)}}

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _}, state) do
      {:noreply,
       %{state | watched: MapSet.delete(state.watched, pid), refs: Map.delete(state.refs, ref)}}
    end
  end

  defmodule AsksItsTable do
    @moduledoc """
    Monitors an owner only where `:ask_owners` has no row for it, and
    writes the ref there; the owner's name goes to `:ask_names`, which a
    cast prunes. The next claim of the same pid finds its row.
    """
    use GenServer

    @impl true
    def init(_) do
      :ets.new(:ask_owners, [:named_table, :public])
      :ets.new(:ask_names, [:named_table, :public])
      {:ok, nil}
    end

    @impl true
    def handle_call({:claim, name, pid}, _from, state) do
      case :ets.lookup(:ask_owners, pid) do
        [] -> :ets.insert(:ask_owners, {pid, Process.monitor(pid)})
        _ -> :ok
      end

      :ets.insert(:ask_names, {name, pid})
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:forget, name}, state) do
      :ets.delete(:ask_names, name)
      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, _}, state) do
      :ets.delete(:ask_owners, pid)
      {:noreply, state}
    end
  end
end
