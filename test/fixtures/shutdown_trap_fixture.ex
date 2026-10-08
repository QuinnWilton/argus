defmodule Argus.Test.Fixtures.ShutdownTrap do
  @moduledoc """
  Trapping GenServers whose handle_info/2 has no {:EXIT, ...} clause, for
  `unhandled_exit_signal`: one linked only to its parent, whose exit
  gen_server takes itself, and the twin that links to a worker of its own.
  """

  defmodule Session do
    @moduledoc "A session the scopes below start under a pool, unlinked."
    use GenServer

    def start(owner), do: DynamicSupervisor.start_child(__MODULE__.Pool, {__MODULE__, owner})
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

    @impl true
    def init(owner), do: {:ok, owner}
  end

  defmodule MonitorsOnly do
    @moduledoc """
    fluffy's test scope: traps exits so that terminate/2 runs on shutdown,
    monitors its owners and the sessions it starts, and links to nothing
    but its parent.
    """
    use GenServer

    alias Argus.Test.Fixtures.ShutdownTrap.Session

    def start_link(owners), do: GenServer.start_link(__MODULE__, owners)

    @impl true
    def init(owners) do
      Process.flag(:trap_exit, true)
      {:ok, %{owners: Map.new(owners, &{Process.monitor(&1), &1}), sessions: %{}}}
    end

    @impl true
    def handle_call({:attach, owner}, _from, state) do
      {:ok, session} = Session.start(owner)
      sessions = Map.put(state.sessions, Process.monitor(session), session)
      {:reply, session, %{state | sessions: sessions}}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _, _}, state) do
      {:noreply, %{state | sessions: Map.delete(state.sessions, ref)}}
    end
  end

  defmodule LinksWorker do
    @moduledoc """
    MonitorsOnly's twin that start_links a worker of its own: the worker's
    exit arrives as an {:EXIT, ...} no clause takes.
    """
    use GenServer

    alias Argus.Test.Fixtures.ShutdownTrap.Session

    def start_link(owners), do: GenServer.start_link(__MODULE__, owners)

    @impl true
    def init(owners) do
      Process.flag(:trap_exit, true)
      {:ok, worker} = Session.start_link(self())
      {:ok, %{owners: Map.new(owners, &{Process.monitor(&1), &1}), worker: worker}}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _, _}, state), do: {:noreply, state}
  end
end
