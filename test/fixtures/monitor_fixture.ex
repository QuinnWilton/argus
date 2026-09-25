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
end
