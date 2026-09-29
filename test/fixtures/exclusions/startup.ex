# Cases for startup exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/startup_test.exs.

# A worker registers with a registry whose pid it is handed, only when
# one is configured: the call (attributed to WorkerRegistry by its tag,
# the target being a pid) holds the start on some inits, not all. It is
# a conditional wait, not an unconditional one.
defmodule Excl.Startup.TagConditional.WorkerRegistry do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  @impl true
  def init(s), do: {:ok, s}

  @impl true
  def handle_call({:join_pool, pid}, _from, s), do: {:reply, :ok, Map.put(s, pid, true)}
end

defmodule Excl.Startup.TagConditional.Worker do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    case Keyword.get(opts, :registry) do
      nil -> :ok
      registry -> :ok = GenServer.call(registry, {:join_pool, self()})
    end

    {:ok, opts}
  end
end

# A proc_lib-started worker holds its registry's pid (handed in, so the
# target is dynamic; the call is attributed by its tag). With
# `sync_register: true` it registers before it acknowledges its start;
# every worker announces itself after the ack, when the start is already
# released. The start waits on the registry only conditionally, and only
# at the register call: the announce holds the server, not the start.
defmodule Excl.Startup.TagAfterAck.WorkerRegistry do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{})

  @impl true
  def init(s), do: {:ok, s}

  @impl true
  def handle_call({:register_worker, pid}, _from, s),
    do: {:reply, :ok, Map.put(s, pid, :registered)}

  def handle_call({:announce_worker, pid}, _from, s),
    do: {:reply, :ok, Map.put(s, pid, :announced)}
end

defmodule Excl.Startup.TagAfterAck.Worker do
  @moduledoc false
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry)

    if Keyword.get(opts, :sync_register, false) do
      register(registry)
    end

    :proc_lib.init_ack({:ok, self()})
    :ok = GenServer.call(registry, {:announce_worker, self()})
    :gen_server.enter_loop(__MODULE__, [], registry)
  end

  defp register(registry), do: :ok = GenServer.call(registry, {:register_worker, self()})
end

# A proc_lib-started server reads its config from a peer before it
# acknowledges its start, then subscribes to the same peer after the ack
# (the start is already released). Only the first call holds the start.
defmodule Excl.Startup.CallAfterAck.Config do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def fetch(key), do: GenServer.call(__MODULE__, {:fetch, key})
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @impl true
  def init(s), do: {:ok, s}

  @impl true
  def handle_call({:fetch, k}, _from, s), do: {:reply, Map.get(s, k), s}
  def handle_call({:subscribe, pid}, _from, s), do: {:reply, :ok, Map.put(s, pid, true)}
end

defmodule Excl.Startup.CallAfterAck.Worker do
  @moduledoc false
  use GenServer
  alias Excl.Startup.CallAfterAck.Config

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    pool = Config.fetch(:pool_size)
    :proc_lib.init_ack({:ok, self()})
    :ok = Config.subscribe(self())
    :gen_server.enter_loop(__MODULE__, [], {opts, pool})
  end
end

# A cache warms itself from the store at start when `warm: true`; the
# supervisor starts the store after the cache. On a warm start init/1
# calls a sibling that is not up yet: a deadlock by construction, which
# the start-order rule reports once, with the tree, and the peer rule
# does not report a second time.
defmodule Excl.Startup.ConditionalLaterSibling.Cache do
  @moduledoc false
  use GenServer
  alias Excl.Startup.ConditionalLaterSibling.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    entries = if Keyword.get(opts, :warm, false), do: Store.all_entries(), else: []
    {:ok, Map.new(entries)}
  end
end

defmodule Excl.Startup.ConditionalLaterSibling.Store do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def all_entries, do: GenServer.call(__MODULE__, :all_entries)

  @impl true
  def init(s), do: {:ok, s}

  @impl true
  def handle_call(:all_entries, _from, s), do: {:reply, s, s}
end

defmodule Excl.Startup.ConditionalLaterSibling.Sup do
  @moduledoc false
  use Supervisor
  alias Excl.Startup.ConditionalLaterSibling.{Cache, Store}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts), do: Supervisor.init([{Cache, opts}, Store], strategy: :one_for_one)
end

# proc_lib-started servers whose init/1 waits once before its ack (that
# wait holds the start) and again, through a helper, after it (that one
# is the server's): a socket greeting read with :infinity, and a port's
# ready line read with a receive that has no `after`. Only the wait
# before the ack is the start's.
defmodule Excl.Startup.WaitAfterAck.Wire do
  @moduledoc false
  use GenServer

  def start_link(host), do: :proc_lib.start_link(__MODULE__, :init, [host])

  @impl true
  def init(host) do
    {:ok, sock} = :gen_tcp.connect(host, 5432, [:binary, active: false])
    greeting = recv_line(sock)
    :proc_lib.init_ack({:ok, self()})
    :ok = handshake(sock)
    :gen_server.enter_loop(__MODULE__, [], {sock, greeting})
  end

  defp handshake(sock) do
    :ok = :gen_tcp.send(sock, "HELLO\r\n")
    "OK" <> _ = recv_line(sock)
    :ok
  end

  defp recv_line(sock) do
    {:ok, line} = :gen_tcp.recv(sock, 0, :infinity)
    line
  end
end

defmodule Excl.Startup.WaitAfterAck.Helper do
  @moduledoc false
  use GenServer

  def start_link(cmd), do: :proc_lib.start_link(__MODULE__, :init, [cmd])

  @impl true
  def init(cmd) do
    port = Port.open({:spawn, cmd}, [:binary])
    :ok = await_ready(port)
    :proc_lib.init_ack({:ok, self()})
    :ok = sync(port)
    :gen_server.enter_loop(__MODULE__, [], port)
  end

  defp sync(port) do
    true = Port.command(port, "sync\n")
    await_ready(port)
  end

  defp await_ready(port) do
    receive do
      {^port, {:data, "ready" <> _}} -> :ok
    end
  end
end

# proc_lib-started servers that release their starter first
# (`:proc_lib.init_ack/1`) and only then do the distributed work: a
# global name registration, a node connect, a dets open. The start is no
# longer held by any of them; what they wait on is the server's.
defmodule Excl.Startup.RemoteAfterAck.GlobalName do
  @moduledoc false
  use GenServer

  def start_link(name), do: :proc_lib.start_link(__MODULE__, :init, [name])

  @impl true
  def init(name) do
    :proc_lib.init_ack({:ok, self()})
    :yes = :global.register_name(name, self())
    :gen_server.enter_loop(__MODULE__, [], name)
  end
end

defmodule Excl.Startup.RemoteAfterAck.Peering do
  @moduledoc false
  use GenServer

  def start_link(seed), do: :proc_lib.start_link(__MODULE__, :init, [seed])

  @impl true
  def init(seed) do
    :proc_lib.init_ack({:ok, self()})
    connected = Node.connect(seed)
    :gen_server.enter_loop(__MODULE__, [], %{seed: seed, connected: connected})
  end
end

defmodule Excl.Startup.RemoteAfterAck.Journal do
  @moduledoc false
  use GenServer

  def start_link(path), do: :proc_lib.start_link(__MODULE__, :init, [path])

  @impl true
  def init(path) do
    :proc_lib.init_ack({:ok, self()})
    {:ok, table} = :dets.open_file(__MODULE__, file: String.to_charlist(path))
    :gen_server.enter_loop(__MODULE__, [], table)
  end
end

# The same distributed work done before the ack: each of the three holds
# the supervisor's start for as long as the cluster or the disk takes.
# What the servers above avoid.
defmodule Excl.Startup.RemoteBeforeAck.Node do
  @moduledoc false
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    :yes = :global.register_name(Keyword.fetch!(opts, :name), self())
    connected = Node.connect(Keyword.fetch!(opts, :seed))
    {:ok, table} = :dets.open_file(__MODULE__, file: String.to_charlist(opts[:path]))
    :proc_lib.init_ack({:ok, self()})
    :gen_server.enter_loop(__MODULE__, [], %{connected: connected, table: table})
  end
end

# init/1 acknowledges its start with :proc_lib.init_ack, then joins a
# cluster-wide :global lock through a helper it calls with a literal
# phase atom, and enters its loop. The lock runs after the ack: the
# starter is already released, so it holds the server, not the start.
defmodule Excl.Startup.LockAfterAck.Leader do
  @moduledoc false
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    :proc_lib.init_ack({:ok, self()})
    state = sync(:boot, opts)
    :gen_server.enter_loop(__MODULE__, [], state)
  end

  defp sync(phase, opts) do
    :global.trans({__MODULE__, self()}, fn -> %{phase: phase, opts: opts} end)
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}
end

# The same leader taking the lock before its ack: the supervisor's start
# waits on the cluster. What the leader above avoids.
defmodule Excl.Startup.LockBeforeAck.Leader do
  @moduledoc false
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    state = sync(:boot, opts)
    :proc_lib.init_ack({:ok, self()})
    :gen_server.enter_loop(__MODULE__, [], state)
  end

  defp sync(phase, opts) do
    :global.trans({__MODULE__, self()}, fn -> %{phase: phase, opts: opts} end)
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}
end

# init/1 acknowledges its start with :proc_lib.init_ack, then elects a
# leader in a task it awaits: the task takes a cluster-wide :global
# lock. The wait comes after the ack, so it holds the server, not the
# start.
defmodule Excl.Startup.TaskAfterAck.Elector do
  @moduledoc false
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    :proc_lib.init_ack({:ok, self()})

    leader =
      Task.async(fn -> :global.trans({:leader, self()}, fn -> node() end) end)
      |> Task.await(:infinity)

    :gen_server.enter_loop(__MODULE__, [], %{opts: opts, leader: leader})
  end

  @impl true
  def handle_call(:leader, _from, state), do: {:reply, state.leader, state}
end

# The same election awaited before the ack: the supervisor's start waits
# on the cluster. What the elector above avoids.
defmodule Excl.Startup.TaskBeforeAck.Elector do
  @moduledoc false
  use GenServer

  def start_link(opts), do: :proc_lib.start_link(__MODULE__, :init, [opts])

  @impl true
  def init(opts) do
    leader =
      Task.async(fn -> :global.trans({:leader, self()}, fn -> node() end) end)
      |> Task.await(:infinity)

    :proc_lib.init_ack({:ok, self()})
    :gen_server.enter_loop(__MODULE__, [], %{opts: opts, leader: leader})
  end

  @impl true
  def handle_call(:leader, _from, state), do: {:reply, state.leader, state}
end
