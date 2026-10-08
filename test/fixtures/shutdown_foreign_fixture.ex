defmodule Argus.Test.Fixtures.ShutdownForeign do
  @moduledoc """
  Processes that start children under a supervisor of another tree, for
  `foreign_dynamic_children`: starters that are themselves in that tree,
  starters whose terminate/2 stops the children through their own stop
  API, task starts bounded by their caller, and the twins that leave
  children behind.
  """

  alias Argus.Test.Fixtures.ShutdownForeign, as: F

  defmodule LibTree do
    @moduledoc "The library's tree: its pools and its task supervisor."
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      children = [
        {DynamicSupervisor,
         name: Argus.Test.Fixtures.ShutdownForeign.Pool, strategy: :one_for_one},
        {DynamicSupervisor,
         name: Argus.Test.Fixtures.ShutdownForeign.SessionPool, strategy: :one_for_one},
        {Task.Supervisor, name: Argus.Test.Fixtures.ShutdownForeign.Tasks}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule OtherTree do
    @moduledoc "Another library's tree, with a pool of its own."
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      children = [
        {DynamicSupervisor,
         name: Argus.Test.Fixtures.ShutdownForeign.OtherPool, strategy: :one_for_one}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule Facade do
    @moduledoc """
    volt's Tailwind supervisor module: the get-or-start API for the
    workers and runtimes the library keeps in its pools.
    """

    def worker(key),
      do: DynamicSupervisor.start_child(F.Pool, {F.Worker, key})

    def stray_worker(key),
      do: DynamicSupervisor.start_child(F.Pool, {F.StrayWorker, key})

    def runtime,
      do: DynamicSupervisor.start_child(F.Pool, {F.Runtime, []})

    def runtime_elsewhere,
      do: DynamicSupervisor.start_child(F.OtherPool, {F.Runtime, []})
  end

  defmodule Runtime do
    @moduledoc "A runtime the library's pools hold."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def stop(pid), do: GenServer.stop(pid, :normal, :infinity)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule Worker do
    @moduledoc """
    A dynamic child of the library's pool that starts its runtime under
    the same pool: both are in the library's tree.
    """
    use GenServer

    def start_link(key), do: GenServer.start_link(__MODULE__, key)

    @impl true
    def init(key) do
      {:ok, runtime} = F.Facade.runtime()
      {:ok, %{key: key, runtime: runtime}}
    end
  end

  defmodule StrayWorker do
    @moduledoc """
    Worker's twin that starts its runtime under the other library's pool:
    that tree is not the one the worker is in.
    """
    use GenServer

    def start_link(key), do: GenServer.start_link(__MODULE__, key)

    @impl true
    def init(key) do
      {:ok, runtime} = F.Facade.runtime_elsewhere()
      {:ok, %{key: key, runtime: runtime}}
    end
  end

  defmodule Session do
    @moduledoc "fluffy's session runtime: a start onto the library's pool, and a stop."
    use GenServer

    def start(owner), do: DynamicSupervisor.start_child(F.SessionPool, {__MODULE__, owner})
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def close(pid), do: GenServer.stop(pid, :normal, :infinity)

    @impl true
    def init(owner), do: {:ok, owner}
  end

  defmodule Scope do
    @moduledoc """
    fluffy's test scope: traps exits, starts sessions under the library's
    pool, and its terminate/2 closes every one of them.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      Process.flag(:trap_exit, true)
      {:ok, %{sessions: %{}}}
    end

    @impl true
    def handle_call({:attach, owner}, _from, state) do
      {:ok, session} = F.Session.start(owner)
      {:reply, session, %{state | sessions: Map.put(state.sessions, session, owner)}}
    end

    @impl true
    def terminate(_reason, state) do
      Enum.each(Map.keys(state.sessions), &F.Session.close/1)
    end
  end

  defmodule CarelessScope do
    @moduledoc """
    Scope's twin whose terminate/2 stops a runtime, not the sessions it
    started: they outlive it.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(runtime) do
      Process.flag(:trap_exit, true)
      {:ok, %{sessions: %{}, runtime: runtime}}
    end

    @impl true
    def handle_call({:attach, owner}, _from, state) do
      {:ok, session} = F.Session.start(owner)
      {:reply, session, %{state | sessions: Map.put(state.sessions, session, owner)}}
    end

    @impl true
    def terminate(_reason, state), do: F.Runtime.stop(state.runtime)
  end

  defmodule Streams do
    @moduledoc """
    snowflex's transport: runs tasks under the library's task supervisor
    and waits for them in the callback. The stream's monitor and the link
    end every task when the caller dies.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:gather, items}, _from, state) do
      results =
        F.Tasks
        |> Task.Supervisor.async_stream_nolink(items, &length/1, on_timeout: :kill_task)
        |> Enum.to_list()

      task = Task.Supervisor.async(F.Tasks, fn -> length(items) end)
      {:reply, {results, Task.await(task)}, state}
    end
  end

  defmodule StreamsAndStrays do
    @moduledoc """
    Streams' twin that also starts a task of its own in the same callback:
    nothing ends that one when the caller dies.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:gather, items}, _from, state) do
      results =
        F.Tasks
        |> Task.Supervisor.async_stream_nolink(items, &length/1, on_timeout: :kill_task)
        |> Enum.to_list()

      {:ok, _} = Task.Supervisor.start_child(F.Tasks, fn -> Process.sleep(:infinity) end)
      {:reply, results, state}
    end
  end
end
