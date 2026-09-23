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
