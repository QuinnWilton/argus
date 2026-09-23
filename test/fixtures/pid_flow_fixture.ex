defmodule Argus.Test.Fixtures.PidFlow do
  @moduledoc """
  Shapes for `Argus.Extractors.PidFlow`: where a pid comes from, and where
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
