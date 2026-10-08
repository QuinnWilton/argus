defmodule Argus.Test.Fixtures.ShutdownMonitors do
  @moduledoc """
  Servers that stop processes while holding monitors, for
  `kills_monitored_child`: stops whose :DOWN no callback can see, stops of
  processes a monitor cannot be on, and the twins that keep the defect.
  """

  defmodule Lib do
    @moduledoc """
    A library process OwnerAndWatchers start_links, as volt's file
    watchers: analyzed beside it, or left out as a dependency is.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule StopsInTerminate do
    @moduledoc """
    Monitors the pids callers hand it and stops them all from terminate/2:
    the server is exiting, so no callback ever sees the :DOWN the stop
    causes.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      Process.flag(:trap_exit, true)
      {:ok, %{running: %{}}}
    end

    @impl true
    def handle_call({:track, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.running[ref], pid)}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, reason}, state) do
      {_, state} = pop_in(state.running[ref])
      {:noreply, Map.put(state, :last_crash, reason)}
    end

    @impl true
    def terminate(_reason, state) do
      Enum.each(state.running, fn {_ref, pid} -> GenServer.stop(pid, :shutdown, 5_000) end)
    end
  end

  defmodule StopsInTerminateAndCast do
    @moduledoc """
    StopsInTerminate with the stop in a helper a cast runs too: on that
    path the server lives on, and the :DOWN lands in its crash clause.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      Process.flag(:trap_exit, true)
      {:ok, %{running: %{}}}
    end

    @impl true
    def handle_call({:track, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.running[ref], pid)}
    end

    @impl true
    def handle_cast(:stop_all, state) do
      stop_all(state)
      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, reason}, state) do
      {_, state} = pop_in(state.running[ref])
      {:noreply, Map.put(state, :last_crash, reason)}
    end

    @impl true
    def terminate(_reason, state), do: stop_all(state)

    defp stop_all(state) do
      Enum.each(state.running, fn {_ref, pid} -> GenServer.stop(pid, :shutdown, 5_000) end)
    end
  end

  defmodule OwnerAndWatchers do
    @moduledoc """
    volt's watcher: monitors the owner its init options name, and stops
    and restarts the library watchers it start_links itself. A process
    the server starts after init cannot be the pid init was handed, so the
    stop cannot be what the owner's monitor reports.
    """
    use GenServer

    alias Argus.Test.Fixtures.ShutdownMonitors.Lib

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      owner_ref = Process.monitor(Keyword.fetch!(opts, :owner))
      {:ok, pid} = Lib.start_link(dir: Keyword.fetch!(opts, :dir))
      {:ok, %{owner_ref: owner_ref, watcher: pid, dir: Keyword.fetch!(opts, :dir)}}
    end

    @impl true
    def handle_info(:refresh, state) do
      GenServer.stop(state.watcher)
      {:ok, pid} = Lib.start_link(dir: state.dir)
      {:noreply, %{state | watcher: pid}}
    end

    def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
      do: {:stop, :normal, state}

    def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}
  end

  defmodule StopsOwner do
    @moduledoc """
    OwnerAndWatchers' twin that stops the owner it monitors, read back
    from its state: the :DOWN of its own stop lands in its owner clause.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)
      owner_ref = Process.monitor(owner)
      {:ok, %{owner_ref: owner_ref, owner: owner}}
    end

    @impl true
    def handle_cast(:release, state) do
      GenServer.stop(state.owner)
      {:noreply, state}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, _}, %{owner_ref: ref} = state),
      do: {:stop, :owner_crashed, state}
  end

  defmodule DemonitorsThenSpawnsStop do
    @moduledoc """
    quickbeam's context: demonitors a worker with :flush, then stops it
    from a task, so the stop's :DOWN never reaches the crash clause.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{workers: %{}}}

    @impl true
    def handle_call({:track, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.workers[pid], ref)}
    end

    def handle_call({:terminate, pid}, _from, state) do
      {ref, workers} = Map.pop(state.workers, pid)
      Process.demonitor(ref, [:flush])
      Task.start(fn -> stop(pid) end)
      {:reply, :ok, %{state | workers: workers}}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
      {_, workers} = Map.pop(state.workers, pid)
      {:noreply, %{state | workers: workers, last_crash: reason}}
    end

    def stop(pid), do: GenServer.stop(pid, :normal, 5_000)
  end

  defmodule SpawnsStopDemonitorsElsewhere do
    @moduledoc """
    DemonitorsThenSpawnsStop's twin whose stop path never demonitors: only
    a cast that forgets a worker does, so the :DOWN of the stop the task
    makes lands in the crash clause.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts), do: {:ok, %{workers: %{}}}

    @impl true
    def handle_call({:track, pid}, _from, state) do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.workers[pid], ref)}
    end

    def handle_call({:terminate, pid}, _from, state) do
      Task.start(fn -> stop(pid) end)
      {:reply, :ok, state}
    end

    @impl true
    def handle_cast({:forget, pid}, state) do
      {ref, workers} = Map.pop(state.workers, pid)
      Process.demonitor(ref, [:flush])
      {:noreply, %{state | workers: workers}}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
      {_, workers} = Map.pop(state.workers, pid)
      {:noreply, %{state | workers: workers, last_crash: reason}}
    end

    def stop(pid), do: GenServer.stop(pid, :normal, 5_000)
  end
end
