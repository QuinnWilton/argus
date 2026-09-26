# Shapes the shutdown analysis keeps quiet, or keeps reported, through
# an exclusion no evaluation program exercises (census 2026-09-26); see
# `test/exclusions/shutdown_test.exs` and docs/design/exclusions.md.

# A watchman tells the event manager it is stopping, from terminate/2.
# The manager is a later sibling, already gone on shutdown, so the
# sync_notify exits :noproc; the try around it takes that exit, and the
# watchman's shutdown finishes.
defmodule Excl.Shutdown.GuardedFarewell.Sup do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Shutdown stops Events first (reverse start order), then the Watchman.
    children = [Excl.Shutdown.GuardedFarewell.Watchman, Excl.Shutdown.GuardedFarewell.Events]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Excl.Shutdown.GuardedFarewell.Events do
  @moduledoc false
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  def start_link, do: :gen_event.start_link({:local, __MODULE__})
end

defmodule Excl.Shutdown.GuardedFarewell.Watchman do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, opts}
  end

  @impl true
  def terminate(reason, _state) do
    try do
      :gen_event.sync_notify(Excl.Shutdown.GuardedFarewell.Events, {:stopping, reason})
    catch
      :exit, _ -> :ok
    end
  end
end

# The same watchman without the try: the :noproc exit from the manager
# already gone crashes its terminate/2. The bug the guarded farewell
# above does not have.
defmodule Excl.Shutdown.BareFarewell.Sup do
  @moduledoc false
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [Excl.Shutdown.BareFarewell.Watchman, Excl.Shutdown.BareFarewell.Events]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Excl.Shutdown.BareFarewell.Events do
  @moduledoc false
  def child_spec(_), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}
  def start_link, do: :gen_event.start_link({:local, __MODULE__})
end

defmodule Excl.Shutdown.BareFarewell.Watchman do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, opts}
  end

  @impl true
  def terminate(reason, _state) do
    :gen_event.sync_notify(Excl.Shutdown.BareFarewell.Events, {:stopping, reason})
  end
end

# A port owner whose listen/1 traps exits, so the port's exit comes as a
# message. The server runs it in init/1, and start_standalone/1 also
# spawns it as a bare process. listen/1 runs on the server's own stack
# too, so the trap is the server's, and its handle_info/2 has no
# {:EXIT, ...} clause: a linked process's exit crashes the server with a
# FunctionClauseError. A real bug the analysis must keep reporting,
# though the trapping function also runs elsewhere.
defmodule Excl.Shutdown.SharedTrap.PortOwner do
  @moduledoc false
  use GenServer

  def start_link(cmd), do: GenServer.start_link(__MODULE__, cmd)
  def start_standalone(cmd), do: spawn_link(__MODULE__, :listen, [cmd])

  @impl true
  def init(cmd), do: {:ok, %{port: listen(cmd), lines: []}}

  def listen(cmd) do
    Process.flag(:trap_exit, true)
    Port.open({:spawn, cmd}, [:binary, :exit_status])
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = s),
    do: {:noreply, %{s | lines: [data | s.lines]}}

  def handle_info({port, {:exit_status, _}}, %{port: port} = s), do: {:stop, :normal, s}
end

# A connection gen_statem (ported from a GenServer) that traps exits in
# init/1 and keeps its old handle_info/2 as the helper its
# handle_event(:info, ...) delegates socket messages to. handle_info/2
# has no {:EXIT, ...} clause, but gen_statem delivers the exit to
# handle_event/4, whose own :EXIT clause takes it first: handle_info/2
# is no callback here and never sees one.
defmodule Excl.Shutdown.StatemInfoHelper.Conn do
  @moduledoc false
  @behaviour :gen_statem

  def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, :connecting, %{opts: opts, sock: nil}}
  end

  @impl true
  def handle_event(:info, {:EXIT, _pid, reason}, _state, data), do: {:stop, reason, data}
  def handle_event(:info, msg, _state, data), do: handle_info(msg, data)
  def handle_event(_type, _event, _state, _data), do: :keep_state_and_data

  def handle_info({:tcp, sock, bytes}, data) do
    :inet.setopts(sock, active: :once)
    {:keep_state, Map.put(data, :last, bytes)}
  end

  def handle_info({:tcp_closed, _sock}, data), do: {:next_state, :connecting, %{data | sock: nil}}
end

# The same connection as a GenServer: it traps exits and its
# handle_info/2, the callback that takes them, has no {:EXIT, ...}
# clause. The bug the gen_statem above does not have.
defmodule Excl.Shutdown.ServerInfo.Conn do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, sock: nil}}
  end

  @impl true
  def handle_info({:tcp, sock, bytes}, data) do
    :inet.setopts(sock, active: :once)
    {:noreply, Map.put(data, :last, bytes)}
  end

  def handle_info({:tcp_closed, _sock}, data), do: {:noreply, %{data | sock: nil}}
end
