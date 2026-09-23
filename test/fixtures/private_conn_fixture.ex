defmodule Argus.Test.Fixtures.PrivateConn do
  @moduledoc """
  A connection module a supervisor starts, and a sibling that starts a
  connection of its own: the sibling's calls, its terminate/2 and its
  stop reach its private connection, not the supervised one.
  """

  defmodule Conn do
    @moduledoc false
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
    def query(conn), do: GenServer.call(conn, :query)
    def stop(conn), do: GenServer.stop(conn)

    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def handle_call(:query, _from, s), do: {:reply, :rows, s}
  end

  defmodule Pool do
    @moduledoc "Keeps a connection of its own, queries it, stops it on reset and in terminate/2."
    use GenServer

    alias Argus.Test.Fixtures.PrivateConn.Conn

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, conn} = Conn.start_link(:private)
      {:ok, %{conn: conn}}
    end

    @impl true
    def handle_call(:query, _from, s), do: {:reply, Conn.query(s.conn), s}

    @impl true
    def handle_cast(:reset, s) do
      Conn.stop(s.conn)
      {:ok, conn} = Conn.start_link(:private)
      {:noreply, %{s | conn: conn}}
    end

    @impl true
    def terminate(_reason, s), do: Conn.query(s.conn)
  end

  defmodule Cache do
    @moduledoc "A named server the supervisor starts."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:get, _from, s), do: {:reply, s, s}
  end

  defmodule Reporter do
    @moduledoc "Calls the supervised Cache by name, in a handler and in terminate/2: the sibling."
    use GenServer

    alias Argus.Test.Fixtures.PrivateConn.Cache

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:report, _from, s), do: {:reply, GenServer.call(Cache, :get), s}

    @impl true
    def terminate(_reason, _s), do: GenServer.call(Cache, :get)
  end

  defmodule Tree do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.PrivateConn.{Cache, Conn, Pool, Reporter}

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil) do
      Supervisor.init([{Conn, :shared}, Pool, Cache, Reporter], strategy: :one_for_one)
    end
  end
end
