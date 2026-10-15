# Servers five modules wait on, and the shapes that make that fan-in a
# bottleneck or not (blocking.dl, sync_call_fan_in). The five callers
# call every server, so each server's count is the same five unless its
# shape is what tells it apart.

defmodule Argus.Test.Fixtures.FanIn.Hot do
  @moduledoc false
  # The bottleneck: one named process doing its work in handle_call/3,
  # and five modules calling its client API with the default timeout.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def lookup(key), do: GenServer.call(__MODULE__, {:lookup, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:lookup, key}, _from, state) do
    Process.sleep(10)
    {:reply, Map.get(state, key), state}
  end
end

defmodule Argus.Test.Fixtures.FanIn.CalledByName do
  @moduledoc false
  # Five modules make GenServer.call themselves, by the name its start
  # registers: no client API, and still one process they all wait on.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:tick, _from, state), do: {:reply, state, state + 1}
end

defmodule Argus.Test.Fixtures.FanIn.Patient do
  @moduledoc false
  # A bottleneck whose every call waits with :infinity: callers queue
  # behind each other but never time out.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def lookup(key), do: GenServer.call(__MODULE__, {:lookup, key}, :infinity)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:lookup, key}, _from, state), do: {:reply, Map.get(state, key), state}
end

defmodule Argus.Test.Fixtures.FanIn.MaybeNamed do
  @moduledoc false
  # Started under whatever name its caller gives: possibly one process
  # every caller shares, so its fan-in still counts.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  def lookup(server, key), do: GenServer.call(server, {:lookup, key})

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:lookup, key}, _from, state), do: {:reply, Map.get(state, key), state}
end

defmodule Argus.Test.Fixtures.FanIn.Instance do
  @moduledoc false
  # One process per start, never named (roux's TableOwner, argus's
  # Engine): five modules calling the API share no process.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def lookup(pid, key), do: GenServer.call(pid, {:lookup, key})

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:lookup, key}, _from, state), do: {:reply, Map.get(state, key), state}
end

defmodule Argus.Test.Fixtures.FanIn.PerKey do
  @moduledoc false
  # One process per key, registered under it: a name, but one per
  # instance.
  use GenServer

  def start_link(key),
    do:
      GenServer.start_link(__MODULE__, key,
        name: {:via, Registry, {Argus.Test.Fixtures.FanIn.Registry, key}}
      )

  def lookup(key),
    do: GenServer.call({:via, Registry, {Argus.Test.Fixtures.FanIn.Registry, key}}, :lookup)

  @impl true
  def init(key), do: {:ok, key}

  @impl true
  def handle_call(:lookup, _from, key), do: {:reply, key, key}
end

defmodule Argus.Test.Fixtures.FanIn.Handoff do
  @moduledoc false
  # One named process whose handle_call/3 queues the caller and runs the
  # work in a process of its own, replying when it ends (argus's
  # Builder): its mailbox keeps moving while the work runs.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def build(job), do: GenServer.call(__MODULE__, {:build, job}, :infinity)

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:build, job}, from, state) do
    {_pid, ref} = spawn_monitor(fn -> exit({:built, job * 2}) end)
    {:noreply, Map.put(state, ref, from)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, {:built, result}}, state) do
    {from, state} = Map.pop(state, ref)
    GenServer.reply(from, {:ok, result})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.FanIn.DefersToItself do
  @moduledoc false
  # Defers its reply, but does the work itself in handle_continue/2: the
  # process is as busy as if it had replied at once.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def build(job), do: GenServer.call(__MODULE__, {:build, job})

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_call({:build, job}, from, state), do: {:noreply, state, {:continue, {from, job}}}

  @impl true
  def handle_continue({from, job}, state) do
    Process.sleep(job)
    GenServer.reply(from, :ok)
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.FanIn.HandsOffOneRequest do
  @moduledoc false
  # Hands one request to a task, and answers the other itself after
  # working on it: that one still queues every caller.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def build(job), do: GenServer.call(__MODULE__, {:build, job})
  def lookup(key), do: GenServer.call(__MODULE__, {:lookup, key})

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:build, job}, from, state) do
    Task.start(fn -> GenServer.reply(from, job * 2) end)
    {:noreply, state}
  end

  def handle_call({:lookup, key}, _from, state) do
    Process.sleep(10)
    {:reply, Map.get(state, key), state}
  end
end

defmodule Argus.Test.Fixtures.FanIn.Wrapped do
  @moduledoc false
  # A named server every caller reaches through one facade function.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def lookup(key), do: GenServer.call(__MODULE__, {:lookup, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:lookup, key}, _from, state), do: {:reply, Map.get(state, key), state}
end

defmodule Argus.Test.Fixtures.FanIn.Facade do
  @moduledoc false
  # The one module calling Wrapped: its callers wait through it.
  def fetch(key), do: Argus.Test.Fixtures.FanIn.Wrapped.lookup(key)
end

for name <- [CallerA, CallerB, CallerC, CallerD, CallerE] do
  defmodule Module.concat(Argus.Test.Fixtures.FanIn, name) do
    @moduledoc false
    alias Argus.Test.Fixtures.FanIn

    def hot(key), do: FanIn.Hot.lookup(key)
    def by_name, do: GenServer.call(FanIn.CalledByName, :tick)
    def patient(key), do: FanIn.Patient.lookup(key)
    def maybe_named(server, key), do: FanIn.MaybeNamed.lookup(server, key)
    def instance(pid, key), do: FanIn.Instance.lookup(pid, key)
    def per_key(key), do: FanIn.PerKey.lookup(key)
    def handoff(job), do: FanIn.Handoff.build(job)
    def defers_to_itself(job), do: FanIn.DefersToItself.build(job)

    def hands_off_one(job),
      do: {FanIn.HandsOffOneRequest.build(job), FanIn.HandsOffOneRequest.lookup(job)}

    def facade(key), do: FanIn.Facade.fetch(key)
  end
end
