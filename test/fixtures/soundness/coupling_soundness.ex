defmodule Argus.Test.Fixtures.Restart do
  @moduledoc """
  Registrations a sibling's restart loses (clientlib/restart_state.dl,
  docs/design/restart-state.md), asserted by test/soundness/coupling_test.exs.

  Each supervisor starts a keeper and a child that registers something
  with it when it starts, under `:one_for_one`. The keepers keep it in a
  different place: the state they return (a map, a flag a literal sets
  to what init/1 does not), a monitor, an ETS row, the process dictionary,
  or a library outside the program. The registrations are made from
  init/1, from handle_continue/2, from a helper init/1 calls and from a
  fun init/1 hands to `Enum.each/2`. The quiet ones call on each use, reset
  a field to its initial value, or only read.
  """
end

defmodule Argus.Test.Fixtures.Restart.ExternalBroker do
  @moduledoc """
  A library's broker, left out of the analyzed program: what a keeper
  hands to it may be kept, and the program cannot see it.
  """
  def subscribe(_topic, _pid), do: :ok
end

# ── Kept in a map state, registered by a cast from init/1 ─────────────

defmodule Argus.Test.Fixtures.Restart.CastSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.CastKeeper, Restart.CastJoiner], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.CastKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def subscribe(pid), do: GenServer.cast(__MODULE__, {:subscribe, pid})

  @impl true
  def init(_), do: {:ok, %{subs: []}}

  @impl true
  def handle_cast({:subscribe, pid}, s), do: {:noreply, %{s | subs: [pid | s.subs]}}
end

defmodule Argus.Test.Fixtures.Restart.CastJoiner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.Restart.CastKeeper.subscribe(self())
    {:ok, nil}
  end
end

# ── Kept as a monitor, registered from handle_continue/2 ──────────────

defmodule Argus.Test.Fixtures.Restart.ContinueSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.ContinueKeeper, Restart.ContinueJoiner], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.ContinueKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def join(pid), do: GenServer.call(__MODULE__, {:join, pid})

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:join, pid}, _from, s) do
    Process.monitor(pid)
    {:reply, :ok, s}
  end

  @impl true
  def handle_info({:DOWN, _, :process, _, _}, s), do: {:noreply, s}
end

defmodule Argus.Test.Fixtures.Restart.ContinueJoiner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :join}}

  @impl true
  def handle_continue(:join, s) do
    :ok = Argus.Test.Fixtures.Restart.ContinueKeeper.join(self())
    {:noreply, s}
  end
end

# ── Kept as an ETS row, registered by a helper init/1 calls ───────────

defmodule Argus.Test.Fixtures.Restart.HookSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.HookKeeper, Restart.HookUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.HookKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def add(hook), do: GenServer.call(__MODULE__, {:add, hook})
  def run(hook), do: :ets.lookup(:restart_fixture_hooks, hook)

  @impl true
  def init(_) do
    :ets.new(:restart_fixture_hooks, [:named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:add, hook}, _from, s) do
    :ets.insert(:restart_fixture_hooks, {hook, :registered})
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Fixtures.Restart.HookUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    register_hooks()
    {:ok, nil}
  end

  defp register_hooks, do: Argus.Test.Fixtures.Restart.HookKeeper.add(:user_hook)
end

# ── Kept as an ETS row, registered by a fun init/1 hands on ───────────

defmodule Argus.Test.Fixtures.Restart.EachSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.EachKeeper, Restart.EachUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.EachKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def add(hook), do: GenServer.call(__MODULE__, {:add, hook})

  @impl true
  def init(_) do
    :ets.new(:restart_fixture_each, [:named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:add, hook}, _from, s) do
    :ets.insert(:restart_fixture_each, {hook, :registered})
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Fixtures.Restart.EachUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(hooks) do
    Enum.each(List.wrap(hooks), &Argus.Test.Fixtures.Restart.EachKeeper.add/1)
    {:ok, nil}
  end
end

# ── Kept by a library the keeper hands it to ──────────────────────────

defmodule Argus.Test.Fixtures.Restart.HandedSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.BrokerClient, Restart.Subscriber], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.BrokerClient do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def subscribe(topic), do: GenServer.call(__MODULE__, {:subscribe, topic})

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:subscribe, topic}, {pid, _}, s) do
    {:reply, Argus.Test.Fixtures.Restart.ExternalBroker.subscribe(topic, pid), s}
  end
end

defmodule Argus.Test.Fixtures.Restart.Subscriber do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    :ok = Argus.Test.Fixtures.Restart.BrokerClient.subscribe("events")
    {:ok, nil}
  end
end

# ── Kept in the process dictionary ────────────────────────────────────

defmodule Argus.Test.Fixtures.Restart.DictSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.DictKeeper, Restart.DictUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.DictKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def register(name), do: GenServer.call(__MODULE__, {:register, name})

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:register, name}, {pid, _}, s) do
    Process.put({:registered, name}, pid)
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Fixtures.Restart.DictUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.Restart.DictKeeper.register(:dict_user)
    {:ok, nil}
  end
end

# ── A flag a bare cast sets to what init/1 does not ───────────────────

defmodule Argus.Test.Fixtures.Restart.FlagSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.FlagKeeper, Restart.FlagUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.FlagKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def ready, do: GenServer.cast(__MODULE__, :ready)

  @impl true
  def init(_), do: {:ok, %{ready: false}}

  @impl true
  def handle_cast(:ready, s), do: {:noreply, %{s | ready: true}}
end

defmodule Argus.Test.Fixtures.Restart.FlagUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.Restart.FlagKeeper.ready()
    {:ok, nil}
  end
end

# ── A keeper that also resets: the registering clause still counts ────

defmodule Argus.Test.Fixtures.Restart.MixedSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.MixedKeeper, Restart.MixedUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.MixedKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)
  def add(item), do: GenServer.cast(__MODULE__, {:add, item})

  @impl true
  def init(_), do: {:ok, %{defs: nil, items: []}}

  @impl true
  def handle_cast(:invalidate, s), do: {:noreply, %{s | defs: nil}}
  def handle_cast({:add, item}, s), do: {:noreply, %{s | items: [item | s.items]}}
end

defmodule Argus.Test.Fixtures.Restart.MixedUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.Restart.MixedKeeper.add(self())
    {:ok, nil}
  end
end

# ── Quiet: a call on each use, by name ────────────────────────────────

defmodule Argus.Test.Fixtures.Restart.PerUseSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.Store, Restart.Relay], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.Store do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def put(k, v), do: GenServer.call(__MODULE__, {:put, k, v})

  @impl true
  def init(_), do: {:ok, %{entries: %{}}}

  @impl true
  def handle_call({:put, k, v}, _from, s),
    do: {:reply, :ok, %{s | entries: Map.put(s.entries, k, v)}}
end

defmodule Argus.Test.Fixtures.Restart.Relay do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def route(k, v), do: GenServer.call(__MODULE__, {:route, k, v})

  @impl true
  def init(_), do: {:ok, 0}

  @impl true
  def handle_call({:route, k, v}, _from, n) do
    :ok = Argus.Test.Fixtures.Restart.Store.put(k, v)
    {:reply, :ok, n + 1}
  end
end

# ── Quiet: a reset to the value init/1 gives the field ────────────────

defmodule Argus.Test.Fixtures.Restart.ResetSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.CacheKeeper, Restart.CacheUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.CacheKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def invalidate, do: GenServer.cast(__MODULE__, :invalidate)

  @impl true
  def init(_), do: {:ok, %{defs: nil}}

  @impl true
  def handle_cast(:invalidate, s), do: {:noreply, %{s | defs: nil}}
end

defmodule Argus.Test.Fixtures.Restart.CacheUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.Restart.CacheKeeper.invalidate()
    {:ok, nil}
  end
end

# ── Quiet: a read at init/1 ───────────────────────────────────────────

defmodule Argus.Test.Fixtures.Restart.ReadSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.ConfigKeeper, Restart.ConfigUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.ConfigKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)

  @impl true
  def init(_), do: {:ok, %{limit: 10}}

  @impl true
  def handle_call(:get, _from, s), do: {:reply, s.limit, s}
end

defmodule Argus.Test.Fixtures.Restart.ConfigUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, Argus.Test.Fixtures.Restart.ConfigKeeper.get()}
end

# ── A keeper with a read clause and a registering one ─────────────────

defmodule Argus.Test.Fixtures.Restart.ClauseSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do:
      Supervisor.init([Restart.ClauseKeeper, Restart.ClauseReader, Restart.ClauseWriter],
        strategy: :one_for_one
      )
end

defmodule Argus.Test.Fixtures.Restart.ClauseKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def get, do: GenServer.call(__MODULE__, :get)
  def put(pid), do: GenServer.call(__MODULE__, {:put, pid})

  @impl true
  def init(_), do: {:ok, %{pids: []}}

  @impl true
  def handle_call(:get, _from, s), do: {:reply, s.pids, s}
  def handle_call({:put, pid}, _from, s), do: {:reply, :ok, %{s | pids: [pid | s.pids]}}
end

defmodule Argus.Test.Fixtures.Restart.ClauseReader do
  @moduledoc "Only reads, from init/1: the clause it enters keeps nothing."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, Argus.Test.Fixtures.Restart.ClauseKeeper.get()}
end

defmodule Argus.Test.Fixtures.Restart.ClauseWriter do
  @moduledoc "Registers from init/1, in the clause that keeps it."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    :ok = Argus.Test.Fixtures.Restart.ClauseKeeper.put(self())
    {:ok, nil}
  end
end

# ── Kept in a state a library call computes (gen_hook's maps:put) ─────

defmodule Argus.Test.Fixtures.Restart.ComputedSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.ComputedKeeper, Restart.ComputedUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.ComputedKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def add_handler(key, fun), do: GenServer.call(__MODULE__, {:add_handler, key, fun})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:add_handler, key, fun}, _from, s),
    do: {:reply, :ok, Map.update(s, key, [fun], &[fun | &1])}
end

defmodule Argus.Test.Fixtures.Restart.ComputedUser do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.Restart.ComputedKeeper.add_handler(:event, &handle_event/1)
    {:ok, nil}
  end

  def handle_event(_), do: :ok
end

# ── Registered through a client API that takes the server ─────────────
#
# eusapia's Notifier: `listen(server, channel)` calls the
# server its caller names, and the listener names the one it was
# configured with. The request resolves to the keeper by its tag, which
# the keeper's own handler takes. The publisher beside it notifies on
# each use and holds nothing.

defmodule Argus.Test.Fixtures.Restart.ServerArgSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do:
      Supervisor.init(
        [Restart.ServerArgKeeper, Restart.ServerArgListener, Restart.ServerArgPublisher],
        strategy: :one_for_one
      )
end

defmodule Argus.Test.Fixtures.Restart.ServerArgKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def listen(server, channel), do: GenServer.call(server, {:listen, channel, self()})
  def notify(server, channel, event), do: GenServer.call(server, {:notify, channel, event})

  @impl true
  def init(_), do: {:ok, %{listeners: %{}}}

  @impl true
  def handle_call({:listen, channel, pid}, _from, s),
    do: {:reply, :ok, %{s | listeners: Map.put(s.listeners, channel, pid)}}

  def handle_call({:notify, channel, event}, _from, s) do
    with {:ok, pid} <- Map.fetch(s.listeners, channel), do: send(pid, {:event, channel, event})
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Fixtures.Restart.ServerArgListener do
  @moduledoc "Listens once, from handle_continue/2, on the keeper it was handed."
  use GenServer

  alias Argus.Test.Fixtures.Restart.ServerArgKeeper

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do: {:ok, %{keeper: Keyword.get(opts, :keeper, ServerArgKeeper)}, {:continue, :listen}}

  @impl true
  def handle_continue(:listen, s) do
    :ok = ServerArgKeeper.listen(s.keeper, :health)
    {:noreply, s}
  end

  @impl true
  def handle_info({:event, :health, _}, s), do: {:noreply, s}
end

defmodule Argus.Test.Fixtures.Restart.ServerArgPublisher do
  @moduledoc "Notifies the keeper it was handed on each use: nothing held."
  use GenServer

  alias Argus.Test.Fixtures.Restart.ServerArgKeeper

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def ping(pid), do: GenServer.call(pid, :ping)

  @impl true
  def init(opts), do: {:ok, %{keeper: Keyword.get(opts, :keeper, ServerArgKeeper)}}

  @impl true
  def handle_call(:ping, _from, s) do
    :ok = ServerArgKeeper.notify(s.keeper, :health, :ping)
    {:reply, :ok, s}
  end
end

# ── The same, by a cast from init/1 ────────────────────────────────────

defmodule Argus.Test.Fixtures.Restart.ServerArgCastSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do:
      Supervisor.init([Restart.ServerArgCastKeeper, Restart.ServerArgCastJoiner],
        strategy: :one_for_one
      )
end

defmodule Argus.Test.Fixtures.Restart.ServerArgCastKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def subscribe(server, pid), do: GenServer.cast(server, {:subscribe, pid})

  @impl true
  def init(_), do: {:ok, %{subs: []}}

  @impl true
  def handle_cast({:subscribe, pid}, s), do: {:noreply, %{s | subs: [pid | s.subs]}}
end

defmodule Argus.Test.Fixtures.Restart.ServerArgCastJoiner do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.Restart.ServerArgCastKeeper

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ServerArgCastKeeper.subscribe(Keyword.get(opts, :keeper, ServerArgCastKeeper), self())
    {:ok, nil}
  end
end

# ── Registered through a helper of the listener's own ────────────────
#
# The listener's handle_continue/2 hands the keeper it was configured
# with to a helper of its own, which calls the keeper's
# `listen(server, channel)`. The registration is the listener's step:
# the handle_continue/2 call, above the helper and the keeper's API.

defmodule Argus.Test.Fixtures.Restart.HelperListenSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do:
      Supervisor.init([Restart.HelperListenKeeper, Restart.HelperListener],
        strategy: :one_for_one
      )
end

defmodule Argus.Test.Fixtures.Restart.HelperListenKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def listen(server, channel), do: GenServer.call(server, {:listen, channel, self()})

  @impl true
  def init(_), do: {:ok, %{listeners: %{}}}

  @impl true
  def handle_call({:listen, channel, pid}, _from, s),
    do: {:reply, :ok, %{s | listeners: Map.put(s.listeners, channel, pid)}}
end

defmodule Argus.Test.Fixtures.Restart.HelperListener do
  @moduledoc "Listens once, from handle_continue/2, through a helper of its own."
  use GenServer

  alias Argus.Test.Fixtures.Restart.HelperListenKeeper

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts),
    do: {:ok, %{keeper: Keyword.get(opts, :keeper, HelperListenKeeper)}, {:continue, :listen}}

  @impl true
  def handle_continue(:listen, s) do
    :ok = listen_on(s.keeper)
    {:noreply, s}
  end

  @impl true
  def handle_info({:event, :health, _}, s), do: {:noreply, s}

  defp listen_on(keeper), do: HelperListenKeeper.listen(keeper, :health)
end

# ── A proxy: a client function that sends another server's tag ───────
#
# `forward/2` takes the server too, but its message is `{:store, _}`,
# which its own module's handler does not take: the request is not the
# proxy's, and resolves to nothing.

defmodule Argus.Test.Fixtures.Restart.ProxySup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.Proxy, Restart.ProxyUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.Proxy do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def forward(server, item), do: GenServer.call(server, {:store, item})
  def count, do: GenServer.call(__MODULE__, :count)

  @impl true
  def init(_), do: {:ok, %{count: 0}}

  @impl true
  def handle_call(:count, _from, s), do: {:reply, s.count, %{s | count: s.count + 1}}
end

defmodule Argus.Test.Fixtures.Restart.ProxyUser do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Argus.Test.Fixtures.Restart.Proxy.forward(Keyword.fetch!(opts, :store), :hello)
    {:ok, nil}
  end
end

# ── A cast made directly in handle_continue/2 ────────────────────────
#
# The joiner's init/1 continues to `:register`, whose clause casts the
# keeper a `{:join, pid}` the keeper keeps in its state: the cast is the
# start's own request, at a site of its once phase, as a call there is.

defmodule Argus.Test.Fixtures.Restart.ContinueCastSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do:
      Supervisor.init([Restart.ContinueCastKeeper, Restart.ContinueCastJoiner],
        strategy: :one_for_one
      )
end

defmodule Argus.Test.Fixtures.Restart.ContinueCastKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{members: []}}

  @impl true
  def handle_cast({:join, pid}, s), do: {:noreply, %{s | members: [pid | s.members]}}
end

defmodule Argus.Test.Fixtures.Restart.ContinueCastJoiner do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.Restart.ContinueCastKeeper

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_), do: {:ok, nil, {:continue, :register}}

  @impl true
  def handle_continue(:register, s) do
    GenServer.cast(ContinueCastKeeper, {:join, self()})
    {:noreply, s}
  end
end

# ── The same cast from a continue only a periodic tick reaches ────────
#
# init/1 arms a tick; the tick re-arms itself and continues to
# `:register`. The clause runs on every tick, so the registration is
# made again after the keeper restarts: not once code.

defmodule Argus.Test.Fixtures.Restart.TickCastSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.TickCastKeeper, Restart.TickCastJoiner], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.TickCastKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{members: []}}

  @impl true
  def handle_cast({:join, pid}, s), do: {:noreply, %{s | members: [pid | s.members]}}
end

defmodule Argus.Test.Fixtures.Restart.TickCastJoiner do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.Restart.TickCastKeeper

  def start_link(_), do: GenServer.start_link(__MODULE__, nil)

  @impl true
  def init(_) do
    Process.send_after(self(), :tick, 1_000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:tick, s) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, s, {:continue, :register}}
  end

  @impl true
  def handle_continue(:register, s) do
    GenServer.cast(TickCastKeeper, {:join, self()})
    {:noreply, s}
  end
end

# ── A cast made on each use ──────────────────────────────────────────
#
# The forwarder casts each item it is handed on to the keeper, from its
# handler: the next item reaches the new keeper, and nothing the
# forwarder made once is lost.

defmodule Argus.Test.Fixtures.Restart.PerUseCastSup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.PerUseCastKeeper, Restart.PerUseCaster], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.PerUseCastKeeper do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{items: []}}

  @impl true
  def handle_cast({:add, item}, s), do: {:noreply, %{s | items: [item | s.items]}}
end

defmodule Argus.Test.Fixtures.Restart.PerUseCaster do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.Restart.PerUseCastKeeper

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def forward(item), do: GenServer.cast(__MODULE__, {:forward, item})

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_cast({:forward, item}, s) do
    GenServer.cast(PerUseCastKeeper, {:add, item})
    {:noreply, s}
  end
end

# ── A cast to a proxy whose handler does not take its tag ────────────
#
# The joiner's handle_continue/2, which init/1 continues to, casts a
# `{:store, _}` to the proxy by name and through the proxy's client
# function that takes the server. The proxy's handler takes only
# `{:bump, _}`: neither request is the proxy's to keep.

defmodule Argus.Test.Fixtures.Restart.CastProxySup do
  @moduledoc false
  use Supervisor
  alias Argus.Test.Fixtures.Restart

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Restart.CastProxy, Restart.CastProxyUser], strategy: :one_for_one)
end

defmodule Argus.Test.Fixtures.Restart.CastProxy do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def forward(server, item), do: GenServer.cast(server, {:store, item})

  @impl true
  def init(_), do: {:ok, %{count: 0}}

  @impl true
  def handle_cast({:bump, n}, s), do: {:noreply, %{s | count: s.count + n}}
end

defmodule Argus.Test.Fixtures.Restart.CastProxyUser do
  @moduledoc false
  use GenServer

  alias Argus.Test.Fixtures.Restart.CastProxy

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, %{store: Keyword.get(opts, :store, CastProxy)}, {:continue, :forward}}

  @impl true
  def handle_continue(:forward, s) do
    GenServer.cast(CastProxy, {:store, :direct})
    CastProxy.forward(s.store, :hello)
    {:noreply, s}
  end
end
