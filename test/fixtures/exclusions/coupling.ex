# Cases for coupling exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/coupling_test.exs.

# A hub that links each subscriber from its own subscribe handler. A
# crash of either side takes the other down with it, so both restart
# together and the subscriber subscribes afresh from init/1: the hub's
# restart loses nothing the subscriber put there.
defmodule Excl.Coupling.LinkedHub.Hub do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def publish(event), do: GenServer.cast(__MODULE__, {:publish, event})

  @impl true
  def init(_opts), do: {:ok, %{subscribers: []}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.link(pid)
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    Enum.each(state.subscribers, &send(&1, {:event, event}))
    {:noreply, state}
  end
end

defmodule Excl.Coupling.LinkedHub.Subscriber do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Excl.Coupling.LinkedHub.Hub.subscribe(self())
    {:ok, []}
  end

  @impl true
  def handle_info({:event, event}, events), do: {:noreply, [event | events]}
end

defmodule Excl.Coupling.LinkedHub.Sup do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([Excl.Coupling.LinkedHub.Hub, Excl.Coupling.LinkedHub.Subscriber],
      strategy: :one_for_one
    )
  end
end

# The same hub without the link: a restart of the hub forgets the
# subscriber, which subscribed once from init/1 and never learns it has
# to again. The bug the linked hub above does not have.
defmodule Excl.Coupling.UnlinkedHub.Hub do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  def publish(event), do: GenServer.cast(__MODULE__, {:publish, event})

  @impl true
  def init(_opts), do: {:ok, %{subscribers: []}}

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    Enum.each(state.subscribers, &send(&1, {:event, event}))
    {:noreply, state}
  end
end

defmodule Excl.Coupling.UnlinkedHub.Subscriber do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = Excl.Coupling.UnlinkedHub.Hub.subscribe(self())
    {:ok, []}
  end

  @impl true
  def handle_info({:event, event}, events), do: {:noreply, [event | events]}
end

defmodule Excl.Coupling.UnlinkedHub.Sup do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Supervisor.init([Excl.Coupling.UnlinkedHub.Hub, Excl.Coupling.UnlinkedHub.Subscriber],
      strategy: :one_for_one
    )
  end
end

# A permanent poller that opens a connection of its own in init/1 and
# queries only that one, beside a temporary shared connection the tree
# starts for migrations. The poller never talks to the temporary child,
# so its never coming back after a crash costs the poller nothing.
defmodule Excl.Coupling.PrivateConn.Conn do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)
  def query(conn, sql), do: GenServer.call(conn, {:query, sql})

  @impl true
  def init(arg), do: {:ok, %{arg: arg}}

  @impl true
  def handle_call({:query, sql}, _from, s), do: {:reply, {:rows, sql}, s}
end

defmodule Excl.Coupling.PrivateConn.Poller do
  @moduledoc false
  use GenServer

  alias Excl.Coupling.PrivateConn.Conn

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    {:ok, conn} = Conn.start_link(:private)
    {:ok, %{conn: conn}}
  end

  @impl true
  def handle_info(:poll, s) do
    _ = Conn.query(s.conn, "select 1")
    {:noreply, s}
  end
end

defmodule Excl.Coupling.PrivateConn.Tree do
  @moduledoc false
  use Supervisor

  alias Excl.Coupling.PrivateConn.{Conn, Poller}

  def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    children = [
      %{id: :migrations_conn, start: {Conn, :start_link, [:shared]}, restart: :temporary},
      Poller
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# The same tree whose poller queries the temporary connection itself,
# by its registered name: once that child crashes it is never started
# again, and every later poll fails. The bug the private connection
# above does not have.
defmodule Excl.Coupling.SharedConn.Conn do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  def query(sql), do: GenServer.call(__MODULE__, {:query, sql})

  @impl true
  def init(arg), do: {:ok, %{arg: arg}}

  @impl true
  def handle_call({:query, sql}, _from, s), do: {:reply, {:rows, sql}, s}
end

defmodule Excl.Coupling.SharedConn.Poller do
  @moduledoc false
  use GenServer

  alias Excl.Coupling.SharedConn.Conn

  def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_info(:poll, s) do
    _ = Conn.query("select 1")
    {:noreply, s}
  end
end

defmodule Excl.Coupling.SharedConn.Tree do
  @moduledoc false
  use Supervisor

  alias Excl.Coupling.SharedConn.{Conn, Poller}

  def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

  @impl true
  def init(nil) do
    children = [
      %{id: :migrations_conn, start: {Conn, :start_link, [:shared]}, restart: :temporary},
      Poller
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# On boot the loader tells its sibling cache to drop what it holds (a
# cast to :invalidate). The cache's :invalidate clause returns through a
# helper that sets `loaded` back to false, the value init/1 starts it
# at: a restart of the cache loses nothing the loader put there.
defmodule Excl.Coupling.ResetHelper.Cache do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)
  def put(data), do: GenServer.cast(__MODULE__, {:put, data})

  @impl true
  def init(_), do: {:ok, %{loaded: false, data: nil}}

  @impl true
  def handle_cast(:invalidate, s), do: invalidate_state(s)
  def handle_cast({:put, data}, s), do: {:noreply, %{s | loaded: true, data: data}}

  defp invalidate_state(s), do: {:noreply, %{s | loaded: false}}
end

defmodule Excl.Coupling.ResetHelper.Loader do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Excl.Coupling.ResetHelper.Cache.invalidate()
    {:ok, %{}}
  end
end

defmodule Excl.Coupling.ResetHelper.Sup do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_),
    do:
      Supervisor.init([Excl.Coupling.ResetHelper.Cache, Excl.Coupling.ResetHelper.Loader],
        strategy: :one_for_one
      )
end

# As above, but the cache's only cast is the invalidation, taken by one
# clause that does not test the request and returns through reset/1,
# which sets `loaded` back to its initial false. A restart of the cache
# loses nothing the loader's cast put there.
defmodule Excl.Coupling.UntestedReset.Cache do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)
  def put(data), do: GenServer.call(__MODULE__, {:put, data})

  @impl true
  def init(_), do: {:ok, %{loaded: false, data: nil}}

  @impl true
  def handle_call({:put, data}, _from, s), do: {:reply, :ok, %{s | loaded: true, data: data}}

  @impl true
  def handle_cast(_invalidate, s), do: reset(s)

  defp reset(s), do: {:noreply, %{s | loaded: false}}
end

defmodule Excl.Coupling.UntestedReset.Loader do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Excl.Coupling.UntestedReset.Cache.invalidate()
    {:ok, %{}}
  end
end

defmodule Excl.Coupling.UntestedReset.Sup do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_),
    do:
      Supervisor.init([Excl.Coupling.UntestedReset.Cache, Excl.Coupling.UntestedReset.Loader],
        strategy: :one_for_one
      )
end

# The same loader and cache, but the cache's :seed clause returns
# through a helper that keeps the payload the loader's boot cast hands
# it: a restart of the cache loses what the loader put there, and the
# loader never sends it again. The bug the reset through a helper above
# does not have.
defmodule Excl.Coupling.TaggedKeep.Cache do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def seed(data), do: GenServer.cast(__MODULE__, {:seed, data})

  @impl true
  def init(_), do: {:ok, %{loaded: false, data: nil}}

  @impl true
  def handle_cast({:seed, data}, s), do: keep(s, data)

  defp keep(s, data), do: {:noreply, %{s | loaded: true, data: data}}
end

defmodule Excl.Coupling.TaggedKeep.Loader do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Excl.Coupling.TaggedKeep.Cache.seed(%{boot: true})
    {:ok, %{}}
  end
end

defmodule Excl.Coupling.TaggedKeep.Sup do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_),
    do:
      Supervisor.init([Excl.Coupling.TaggedKeep.Cache, Excl.Coupling.TaggedKeep.Loader],
        strategy: :one_for_one
      )
end

# As above, with one untested clause taking the boot cast and returning
# through the helper that keeps its payload. The bug the untested reset
# above does not have.
defmodule Excl.Coupling.UntestedKeep.Cache do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def seed(data), do: GenServer.cast(__MODULE__, {:seed, data})

  @impl true
  def init(_), do: {:ok, %{loaded: false, data: nil}}

  @impl true
  def handle_cast(seed, s), do: keep(s, seed)

  defp keep(s, data), do: {:noreply, %{s | loaded: true, data: data}}
end

defmodule Excl.Coupling.UntestedKeep.Loader do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Excl.Coupling.UntestedKeep.Cache.seed(%{boot: true})
    {:ok, %{}}
  end
end

defmodule Excl.Coupling.UntestedKeep.Sup do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_),
    do:
      Supervisor.init([Excl.Coupling.UntestedKeep.Cache, Excl.Coupling.UntestedKeep.Loader],
        strategy: :one_for_one
      )
end
