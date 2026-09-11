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
