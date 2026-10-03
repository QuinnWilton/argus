defmodule Argus.Test.Fixtures.PidFlow do
  @moduledoc """
  Shapes for `Argus.Extractors.TermFlow`: where a pid comes from, and where
  it goes. The quiet ones start or reach a process nothing can name.
  """

  defmodule Worker do
    @moduledoc "A server started through a wrapper, called through its API."
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def ping(pid), do: GenServer.call(pid, :ping)
    def notify(pid), do: GenServer.cast(pid, :note)

    @impl true
    def init(owner), do: {:ok, owner}

    @impl true
    def handle_call(:ping, _from, owner), do: {:reply, :pong, owner}

    @impl true
    def handle_cast(:note, owner), do: {:noreply, owner}
  end

  defmodule Owner do
    @moduledoc "Pids from a wrapper's result, a direct start, across a call, through two parameters."
    alias Argus.Test.Fixtures.PidFlow.Worker

    def run do
      {:ok, pid} = Worker.start_link(self())
      Worker.ping(pid)
      hand_off(pid)
    end

    def direct do
      {:ok, pid} = GenServer.start_link(Worker, :arg)
      GenServer.call(pid, :ping)
    end

    def across_a_call do
      {:ok, pid} = GenServer.start_link(Worker, :arg)
      :ok = Worker.notify(:elsewhere)
      GenServer.call(pid, :ping)
    end

    def dynamic do
      {:ok, pid} = DynamicSupervisor.start_child(:workers, {Worker, :arg})
      GenServer.call(pid, :ping)
    end

    defp hand_off(p), do: relay(p)
    defp relay(q), do: Worker.notify(q)

    # `first` dies before `second`, so the frame is trimmed and `second`
    # moves down a slot before the call that targets it.
    def across_a_trim do
      {:ok, first} = GenServer.start_link(Worker, :first)
      {:ok, second} = GenServer.start_link(Worker, :second)
      :ok = GenServer.call(first, :ping)
      :ok = Worker.notify(:elsewhere)
      GenServer.call(second, :ping)
    end
  end

  defmodule Loops do
    @moduledoc "A spawned loop registered under a name and sent to by it; a closure that captures a pid."
    def start do
      pid = spawn(__MODULE__, :loop, [])
      Process.register(pid, :loops)
      send(:loops, :tick)
      spawn(fn -> send(pid, {:done, 1}) end)
    end

    def loop do
      receive do
        :tick -> loop()
      end
    end
  end

  defmodule CycleA do
    @moduledoc """
    Starts B with its own pid; each holds the other's pid in its state and
    calls it. Both handle both tags, so tag attribution cannot say who a
    call reaches: only following the pid can.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.CycleB

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil) do
      {:ok, b} = CycleB.start_link(self())
      {:ok, b}
    end

    @impl true
    def handle_call(:ask, _from, b), do: {:reply, GenServer.call(b, :ping), b}
    def handle_call(:ping, _from, b), do: {:reply, :pong, b}
    def handle_call(:pong, _from, b), do: {:reply, :ok, b}
  end

  defmodule CycleB do
    @moduledoc "Keeps the pid it was started with and calls back into it."
    use GenServer

    def start_link(a), do: GenServer.start_link(__MODULE__, a)

    @impl true
    def init(a), do: {:ok, a}

    @impl true
    def handle_call(:ping, _from, a), do: {:reply, GenServer.call(a, :pong), a}
    def handle_call(:pong, _from, a), do: {:reply, :ok, a}
  end

  defmodule Tree do
    @moduledoc "A supervisor whose child starts through a helper: only the child spec names the server."
    use Supervisor

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: Supervisor.init([Argus.Test.Fixtures.PidFlow.Kid], strategy: :one_for_one)
  end

  defmodule Kid do
    @moduledoc false
    use GenServer

    def start_link(_), do: Argus.Test.Fixtures.PidFlow.Starter.go(__MODULE__)

    @impl true
    def init(nil), do: {:ok, self()}
  end

  defmodule Starter do
    @moduledoc false
    def go(mod), do: GenServer.start_link(mod, nil)
  end

  defmodule Hub do
    @moduledoc """
    Keeps the pids that subscribe with a cast and calls the first. Both
    servers handle both tags, so only following the pid through the
    message and into the hub's state says who the hub calls.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
    def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})
    def poll, do: GenServer.call(__MODULE__, :poll)

    @impl true
    def init(subs), do: {:ok, subs}

    @impl true
    def handle_cast({:subscribe, pid}, subs), do: {:noreply, [pid | subs]}

    @impl true
    def handle_call(:poll, _from, [first | _] = subs),
      do: {:reply, GenServer.call(first, :ping), subs}

    def handle_call(:ping, _from, subs), do: {:reply, :pong, subs}
  end

  defmodule Listener do
    @moduledoc "Subscribes itself to the hub, and polls it when pinged."
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.Hub

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil) do
      Hub.subscribe(self())
      {:ok, nil}
    end

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, Hub.poll(), s}
    def handle_call(:poll, _from, s), do: {:reply, :ok, s}
  end

  defmodule Front do
    @moduledoc """
    Starts Back and Side privately and keeps both pids in one state map,
    but calls only Back. Side calls Front back: a cycle exists only if
    the state is one bag of pids.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{Back, Side}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      {:ok, back} = Back.start_link()
      {:ok, side} = Side.start_link()
      {:ok, %{back: back, side: side}}
    end

    @impl true
    def handle_call(:go, _from, state), do: {:reply, GenServer.call(state.back, :ping), state}
  end

  defmodule Back do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  end

  defmodule Side do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:poke, _from, s),
      do: {:reply, GenServer.call(Argus.Test.Fixtures.PidFlow.Front, :go), s}
  end

  defmodule Relay do
    @moduledoc """
    Keeps a spawned worker and its subscribers in separate fields: an
    event goes to the first subscriber, a flush to the worker.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})

    @impl true
    def init(:ok) do
      worker = spawn(__MODULE__, :worker_loop, [])
      {:ok, %{worker: worker, subs: []}}
    end

    def worker_loop do
      receive do
        :flush -> worker_loop()
      end
    end

    @impl true
    def handle_cast({:subscribe, pid}, s), do: {:noreply, %{s | subs: [pid | s.subs]}}

    @impl true
    def handle_info(:tick, s) do
      send(hd(s.subs), :event)
      send(s.worker, :flush)
      {:noreply, s}
    end
  end

  defmodule Subscriber do
    @moduledoc "A spawned subscriber that waits for one event."
    def go do
      me = spawn(fn -> await() end)
      Argus.Test.Fixtures.PidFlow.Relay.subscribe(me)
    end

    defp await do
      receive do
        :event -> :ok
      end
    end
  end

  defmodule SafeCall do
    @moduledoc "A helper every server calls its peer through."
    def safe_call(pid, msg), do: GenServer.call(pid, msg)
    def call_peer(state), do: GenServer.call(state.peer, :ping)
  end

  defmodule UserA do
    @moduledoc """
    Calls its private peer through the shared helpers. UserB does the
    same with another peer, which calls UserA back by name: only a helper
    whose parameter is every caller's pid at once makes that a cycle.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{SafeCall, TargetA}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      {:ok, peer} = TargetA.start_link()
      {:ok, %{peer: peer}}
    end

    @impl true
    def handle_call(:go, _from, s), do: {:reply, SafeCall.safe_call(s.peer, :ping), s}
    def handle_call(:field, _from, s), do: {:reply, SafeCall.call_peer(s), s}
  end

  defmodule UserB do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{SafeCall, TargetB}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      {:ok, peer} = TargetB.start_link()
      {:ok, %{peer: peer}}
    end

    @impl true
    def handle_call(:go, _from, s), do: {:reply, SafeCall.safe_call(s.peer, :ping), s}
    def handle_call(:field, _from, s), do: {:reply, SafeCall.call_peer(s), s}
  end

  defmodule TargetA do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  end

  defmodule TargetB do
    @moduledoc false
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s),
      do: {:reply, GenServer.call(Argus.Test.Fixtures.PidFlow.UserA, :go), s}
  end

  defmodule Timed do
    @moduledoc """
    Waits on its peer forever, and on itself with the default timeout:
    the peer's dependency carries the peer call's timeout.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      {:ok, peer} = Argus.Test.Fixtures.PidFlow.TargetA.start_link()
      {:ok, %{peer: peer}}
    end

    @impl true
    def handle_call(:go, _from, s), do: {:reply, GenServer.call(s.peer, :ping, :infinity), s}
    def handle_call(:me, _from, s), do: {:reply, GenServer.call(self(), :go), s}
  end

  defmodule Starts do
    @moduledoc """
    Starts beyond start_link: a monitored start, tasks, an agent, a spawn
    on a node, and a pid handed to a seven-argument function.
    """
    alias Argus.Test.Fixtures.PidFlow.Back

    def monitored do
      {:ok, {pid, _ref}} = :gen_server.start_monitor(Back, :ok, [])
      GenServer.call(pid, :ping)
    end

    def tasks do
      task = Task.async(fn -> :done end)
      send(task.pid, :hello)
      {:ok, pid} = Task.start_link(fn -> await_go() end)
      send(pid, :stop)
    end

    defp await_go do
      receive do
        :go -> :ok
      end
    end

    def agent do
      {:ok, agent} = Agent.start_link(fn -> 0 end, name: :counter)
      Agent.get(agent, & &1)
    end

    def remote do
      Node.spawn(Node.self(), __MODULE__, :relay, [self()])
    end

    def relay(parent), do: send(parent, :relayed)

    def wide do
      pid = spawn(fn -> :ok end)
      seven(1, 2, 3, 4, 5, pid, 7)
    end

    def seven(_a, _b, _c, _d, _e, pid, _g), do: send(pid, :sixth)
  end

  defmodule Names do
    @moduledoc """
    A server named globally and looked up in all three registries; a
    registration of another pid, which the module-level guess would have
    taken for the caller's own.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: {:global, :names})

    def ping_global, do: GenServer.call(:global.whereis_name(:names), :ping)
    def ping_whereis, do: GenServer.call(GenServer.whereis({:global, :names}), :ping)

    def ping_registry do
      [{pid, _}] = Registry.lookup(Argus.Test.Fixtures.PidFlow.Reg, :names)
      GenServer.call(pid, :ping)
    end

    def park do
      helper = spawn(fn -> :ok end)
      Process.register(helper, :names_helper)
      send(:names_helper, :hi)
    end

    @impl true
    def init(:ok) do
      Registry.register(Argus.Test.Fixtures.PidFlow.Reg, :names, nil)
      {:ok, nil}
    end

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  end

  defmodule NamedTree do
    @moduledoc "A child spec that names its child."
    use Supervisor

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil) do
      Supervisor.init([{Argus.Test.Fixtures.PidFlow.Worker, name: :named_worker}],
        strategy: :one_for_one
      )
    end
  end

  defmodule SelfHelper do
    @moduledoc "A spawned loop whose helper sends to self() a message the loop never takes."
    def start, do: spawn(__MODULE__, :loop, [])

    def loop do
      remind()

      receive do
        :tick -> loop()
      end
    end

    defp remind, do: send(self(), :reminder)
  end

  defmodule Machine do
    @moduledoc "A gen_statem keeping a private peer in its data and calling it from a state."
    @behaviour :gen_statem

    alias Argus.Test.Fixtures.PidFlow.Back

    def start_link, do: :gen_statem.start_link(__MODULE__, :ok, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(:ok) do
      {:ok, peer} = Back.start_link()
      {:ok, :idle, %{peer: peer}}
    end

    def idle({:call, from}, :go, data) do
      :pong = GenServer.call(data.peer, :ping)
      {:keep_state, data, [{:reply, from, :ok}]}
    end
  end

  defmodule PlugLike do
    @moduledoc "A plug whose init/1 calls a server: it runs in whoever calls it, not as a process."
    @behaviour Plug

    @impl true
    def init(opts) do
      :pong = GenServer.call(Argus.Test.Fixtures.PidFlow.Hub, :poll)
      opts
    end

    @impl true
    def call(conn, _opts), do: conn
  end

  defmodule Keeper do
    @moduledoc """
    Starts a helper it keeps in its state and kills it on reset; monitors
    a spawned watcher; kills a peer it was handed through a helper; and
    calls itself by name and by self() from its own callbacks.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok) do
      helper = spawn_link(fn -> Process.sleep(:infinity) end)
      watcher = spawn(fn -> :ok end)
      _ref = Process.monitor(watcher)
      {:ok, %{helper: helper}}
    end

    @impl true
    def handle_cast(:reset, s) do
      Process.exit(s.helper, :kill)
      {:noreply, s}
    end

    def handle_cast({:drop, peer}, s) do
      stop(peer)
      {:noreply, s}
    end

    @impl true
    def handle_call(:me, _from, s), do: {:reply, GenServer.call(self(), :ping), s}
    def handle_call(:named, _from, s), do: {:reply, GenServer.call(__MODULE__, :ping), s}
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}

    defp stop(pid), do: Process.exit(pid, :shutdown)
  end

  defmodule KeeperClient do
    @moduledoc "Hands the keeper a peer to drop."
    def drop do
      {:ok, peer} = Argus.Test.Fixtures.PidFlow.Back.start_link()
      GenServer.cast(Argus.Test.Fixtures.PidFlow.Keeper, {:drop, peer})
    end
  end

  defmodule Directory do
    @moduledoc "Starts workers under keys it does not know and hands them out on request."
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.Back

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
    def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})

    @impl true
    def init(:ok), do: {:ok, %{workers: %{}}}

    @impl true
    def handle_cast({:add, id}, s) do
      {:ok, pid} = Back.start_link()
      {:noreply, %{s | workers: Map.put(s.workers, id, pid)}}
    end

    @impl true
    def handle_call({:lookup, id}, _from, s), do: {:reply, Map.get(s.workers, id), s}
  end

  defmodule Carrier do
    @moduledoc "Reads a map holding a pid under a literal key by a key it does not know."
    def call_any(key) do
      {:ok, back} = Argus.Test.Fixtures.PidFlow.Back.start_link()
      socket = %{transport: back}
      GenServer.call(Map.get(socket, key), :ping)
    end
  end

  defmodule DirectoryClient do
    @moduledoc "Calls the worker the directory hands it."
    def ping(id), do: GenServer.call(Argus.Test.Fixtures.PidFlow.Directory.lookup(id), :ping)
  end

  defmodule Conn do
    @moduledoc "A connection a supervisor starts, and a module may also start for itself."
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init(arg), do: {:ok, arg}

    @impl true
    def handle_call(:query, _from, s), do: {:reply, :rows, s}
  end

  defmodule ConnUser do
    @moduledoc "Starts a private connection and queries it: not the supervised sibling."
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.Conn

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, conn} = Conn.start_link(:private)
      {:ok, %{conn: conn}}
    end

    @impl true
    def handle_call(:query, _from, s), do: {:reply, GenServer.call(s.conn, :query), s}
  end

  defmodule DictConnUser do
    @moduledoc """
    ConnUser, keeping the connection in its dictionary: init/1 puts it,
    and handle_call/3 reads it back through a helper.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.Conn

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, conn} = Conn.start_link(:private)
      Process.put(:dict_conn, conn)
      {:ok, nil}
    end

    @impl true
    def handle_call(:query, _from, s), do: {:reply, GenServer.call(conn(), :query), s}

    # Called by the process's callers, in their own processes: nothing
    # they run put the key.
    def query_directly, do: GenServer.call(conn(), :query)

    defp conn, do: Process.get(:dict_conn)
  end

  defmodule DictMapConnUser do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.Conn

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, conn} = Conn.start_link(:private)
      Process.put(:connection, %{conn: conn, unrelated: self()})
      {:ok, nil}
    end

    @impl true
    def handle_call(:query, _from, state) do
      {:reply, GenServer.call(Process.get(:connection).conn, :query), state}
    end

    def query_directly, do: GenServer.call(Process.get(:connection).conn, :query)
  end

  defmodule ConnSup do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.PidFlow.{Conn, ConnUser}

    def start_link(_), do: Supervisor.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: Supervisor.init([{Conn, :shared}, ConnUser], strategy: :one_for_one)
  end

  defmodule Joiner do
    @moduledoc "self() in a closure Enum.each runs is the server; in one a task runs, the task."
    use GenServer

    def start_link(hubs), do: GenServer.start_link(__MODULE__, hubs)

    @impl true
    def init(hubs) do
      Enum.each(hubs, fn hub -> send(hub, {:join, self()}) end)
      Task.start(fn -> send(:joiners, {:hello, self()}) end)
      {:ok, hubs}
    end
  end

  defmodule Reindexer do
    @moduledoc "Calls the AnyCall it started with :reindex, a tag only Decoy's handle_call names."
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.AnyCall

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      {:ok, index} = AnyCall.start_link()
      {:ok, %{index: index}}
    end

    @impl true
    def handle_call(:rebuild, _from, s), do: {:reply, GenServer.call(s.index, :reindex), s}
  end

  defmodule AnyCall do
    @moduledoc "Takes every call in one clause: no tag of its own."
    use GenServer

    def start_link, do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(msg, _from, s), do: {:reply, msg, s}
  end

  defmodule Decoy do
    @moduledoc "The only handler that names :reindex."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:reindex, _from, s), do: {:reply, :ok, s}
  end

  defmodule Answerer do
    @moduledoc "A named server."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ask, _from, s), do: {:reply, :answer, s}
  end

  defmodule ProxyApi do
    @moduledoc "A GenServer whose public ask/0 calls Answerer, not itself."
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.Answerer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)
    def ask, do: GenServer.call(Answerer, :ask)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:noop, _from, s), do: {:reply, :ok, s}
  end

  defmodule ProxyUser do
    @moduledoc "Asks through ProxyApi: it waits on Answerer."
    def use, do: Argus.Test.Fixtures.PidFlow.ProxyApi.ask()
  end

  defmodule NamedCall do
    @moduledoc """
    A helper servers call a peer through by the peer's name, and a wrapper
    of it: the name each caller passes is that caller's target alone.
    """
    def call(server, msg), do: GenServer.call(server, msg)
    def ping(server), do: call(server, :ping)
  end

  defmodule NamedUserA do
    @moduledoc """
    Calls NamedTargetA through the helper; NamedUserB calls NamedTargetB
    through its wrapper, and NamedTargetB calls NamedUserA back by name.
    Only a helper whose parameter is every caller's name at once makes
    that a cycle.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{NamedCall, NamedTargetA}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:go, _from, s), do: {:reply, NamedCall.call(NamedTargetA, :ping), s}
  end

  defmodule NamedUserB do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{NamedCall, NamedTargetB}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:go, _from, s), do: {:reply, NamedCall.ping(NamedTargetB), s}
  end

  defmodule NamedTargetA do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, :pong, s}
  end

  defmodule NamedTargetB do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s),
      do: {:reply, GenServer.call(Argus.Test.Fixtures.PidFlow.NamedUserA, :go), s}
  end

  defmodule NamedPeerA do
    @moduledoc """
    Calls NamedPeerB through the helper's wrapper, which calls NamedPeerA
    back through it: a cycle through the helper both ways.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{NamedCall, NamedPeerB}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, NamedCall.ping(NamedPeerB), s}
  end

  defmodule NamedPeerB do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{NamedCall, NamedPeerA}

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(:ping, _from, s), do: {:reply, NamedCall.ping(NamedPeerA), s}
  end

  defmodule Pass do
    @moduledoc """
    Helpers that hand their parameter back: as it came, through a second
    helper, and after counting down to it.
    """
    def same(x), do: x
    def via(x), do: same(x)
    def after_count(x, 0), do: x
    def after_count(x, n), do: after_count(x, n - 1)
  end

  defmodule PassUserA do
    @moduledoc """
    Calls its private peer after handing it through Pass's helpers, bare
    and inside a term. PassUserB does the same with another peer: merged
    at a helper's parameter, each would call both peers.
    """
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{Pass, TargetA}

    @impl true
    def init(:ok) do
      {:ok, peer} = TargetA.start_link()
      {:ok, %{peer: peer}}
    end

    @impl true
    def handle_call(:same, _from, s), do: {:reply, GenServer.call(Pass.same(s.peer), :ping), s}
    def handle_call(:via, _from, s), do: {:reply, GenServer.call(Pass.via(s.peer), :ping), s}

    def handle_call(:count, _from, s),
      do: {:reply, GenServer.call(Pass.after_count(s.peer, 3), :ping), s}

    def handle_call(:held, _from, s) do
      held = Pass.same(%{held: s.peer})
      {:reply, GenServer.call(held.held, :ping), s}
    end
  end

  defmodule PassUserB do
    @moduledoc false
    use GenServer

    alias Argus.Test.Fixtures.PidFlow.{Pass, TargetB}

    @impl true
    def init(:ok) do
      {:ok, peer} = TargetB.start_link()
      {:ok, %{peer: peer}}
    end

    @impl true
    def handle_call(:same, _from, s), do: {:reply, GenServer.call(Pass.same(s.peer), :ping), s}
    def handle_call(:via, _from, s), do: {:reply, GenServer.call(Pass.via(s.peer), :ping), s}

    def handle_call(:count, _from, s),
      do: {:reply, GenServer.call(Pass.after_count(s.peer, 3), :ping), s}

    def handle_call(:held, _from, s) do
      held = Pass.same(%{held: s.peer})
      {:reply, GenServer.call(held.held, :ping), s}
    end
  end

  defmodule Nested do
    @moduledoc "Keeps its peer three terms deep, built in one function and read out in another."
    alias Argus.Test.Fixtures.PidFlow.TargetA

    def boxed do
      {:ok, peer} = TargetA.start_link()
      {:box, [%{inner: {:peer, peer}}]}
    end

    def unbox do
      {:box, [m | _]} = boxed()
      {:peer, p} = m.inner
      GenServer.call(p, :ping)
    end
  end

  defmodule StatemClient do
    @moduledoc "Reaches a gen_statem through a wrapper that forwards its target."
    def status, do: do_call(Argus.Test.Fixtures.PidFlow.Machine, :status)

    defp do_call(server, msg), do: :gen_statem.call(server, msg)
  end

  defmodule Quiet do
    @moduledoc "Starts with a computed module, apply, and a pid from a library call: no process to name."
    def applied(m), do: apply(m, :start_link, [])

    def dynamic_module(m) do
      {:ok, pid} = GenServer.start_link(m, [])
      GenServer.call(pid, :ping)
    end

    def from_library do
      pid = :erlang.list_to_pid(~c"<0.1.0>")
      send(pid, :hi)
    end
  end
end
