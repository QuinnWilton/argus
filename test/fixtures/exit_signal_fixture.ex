defmodule Argus.Test.Fixtures.ExitSignals do
  @moduledoc """
  Fixtures for `failure.orphan_process`: an exit signal from a callback to
  a process the server started itself (quiet), to a child a supervisor
  owns (reported, with the supervisor), and spawns something watches
  (quiet).
  """

  defmodule OwnHelper do
    @moduledoc "Starts a helper, keeps it in its state and kills it on reset: its own to stop."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      helper = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, %{helper: helper}}
    end

    @impl true
    def handle_cast(:reset, s) do
      Process.exit(s.helper, :kill)
      {:noreply, s}
    end
  end

  defmodule Worker do
    @moduledoc "A named worker its supervisor owns."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}
  end

  defmodule Tree do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.ExitSignals.{Killer, Worker}

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: Supervisor.init([Worker, Killer], strategy: :one_for_one)
  end

  defmodule Killer do
    @moduledoc "Kills the worker its supervisor owns, by name, from a callback."
    use GenServer

    alias Argus.Test.Fixtures.ExitSignals.Worker

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_cast(:bounce, s) do
      Process.exit(Process.whereis(Worker), :kill)
      {:noreply, s}
    end
  end

  defmodule Watched do
    @moduledoc "Spawns processes it monitors or links to: their crashes are seen."
    def monitored do
      pid = spawn(fn -> :ok end)
      Process.monitor(pid)
    end

    def linked do
      pid = spawn(fn -> :ok end)
      Process.link(pid)
      pid
    end

    def unwatched, do: spawn(fn -> :ok end)
  end
end
