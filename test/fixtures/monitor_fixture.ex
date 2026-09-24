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
end
