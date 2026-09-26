# Messages a server is shown to be sent, and has no clause for: the
# witnessed sources `unhandled_info` reads in place of the retired
# "handle_info/2 has no catch-all" (test/soundness/mailbox_test.exs
# asserts each positive; test/analyses/mailbox_unhandled_info_test.exs
# the quiet neighbours).

# ── A monitor's :DOWN: the reason is the runtime's ──────────────────────

defmodule Argus.Test.Soundness.Witness.DownOnlyNormal do
  @moduledoc false
  # Takes its worker's :DOWN only when the worker exits :normal: a crash
  # of the worker is a FunctionClauseError in the server.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state),
    do: {:noreply, Map.delete(state, ref)}
end

defmodule Argus.Test.Soundness.Witness.DownGuardIn do
  @moduledoc false
  # A guard on the reason: :killed and every crash reason fall through.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when reason in [:normal, :shutdown],
      do: {:noreply, Map.delete(state, ref)}
end

defmodule Argus.Test.Soundness.Witness.DownShutdownOnly do
  @moduledoc false
  # A pattern on the reason, in a monitor a helper module takes on the
  # server's stack: `{:shutdown, _}` is one reason of many.
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(peer) do
    ref = Argus.Test.Soundness.Witness.Watch.watch(peer)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, {:shutdown, _}}, %{ref: ref} = state),
    do: {:stop, :normal, state}
end

defmodule Argus.Test.Soundness.Witness.Watch do
  @moduledoc false
  def watch(peer), do: Process.monitor(peer)
end

defmodule Argus.Test.Soundness.Witness.PortDownPinned do
  @moduledoc false
  # Monitors a port and pins the ref, but compares the type with
  # :process: the port's :DOWN says :port.
  use GenServer

  def start_link(port), do: GenServer.start_link(__MODULE__, port)

  @impl true
  def init(port) do
    ref = :erlang.monitor(:port, port)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _port, _reason}, %{ref: ref} = state),
    do: {:stop, :normal, state}
end

# Quiet neighbours: the clauses between them take every reason, or the
# clause asks only what the program chose (the ref, the state).

defmodule Argus.Test.Soundness.Witness.DownSplitReasons do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, :normal}, state),
    do: {:noreply, Map.delete(state, ref)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state),
    do: {:noreply, Map.delete(state, ref)}
end

defmodule Argus.Test.Soundness.Witness.DownReasonInBody do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, %{}}

  @impl true
  def handle_cast({:watch, pid}, state) do
    ref = Process.monitor(pid)
    {:noreply, Map.put(state, ref, pid)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case reason do
      :normal -> {:noreply, Map.delete(state, ref)}
      _ -> {:stop, reason, state}
    end
  end
end

defmodule Argus.Test.Soundness.Witness.PortDownAnyType do
  @moduledoc false
  use GenServer

  def start_link(port), do: GenServer.start_link(__MODULE__, port)

  @impl true
  def init(port) do
    ref = :erlang.monitor(:port, port)
    {:ok, %{ref: ref}}
  end

  @impl true
  def handle_info({:DOWN, ref, _type, _port, _reason}, %{ref: ref} = state),
    do: {:stop, :normal, state}
end
