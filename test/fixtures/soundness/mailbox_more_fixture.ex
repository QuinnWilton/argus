# Mailbox bugs review 2 found silenced (items 23, 25, 26, 33, 34):
# test/soundness/mailbox_test.exs asserts the finding each must keep.
# Lib.Warmer stands for a library outside the program: never analyzed.

defmodule Argus.Test.Soundness.Mailbox.Lib.Warmer do
  @moduledoc false
  # A library's `use`: a GenServer whose handle_info/2 takes only the
  # library's own tick, and calls the user's execute/1 on it.
  @callback execute(term) :: term

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Argus.Test.Soundness.Mailbox.Lib.Warmer

      def start_link(state), do: GenServer.start_link(__MODULE__, state)

      def init(state) do
        Process.send_after(self(), :warmer_tick, 0)
        {:ok, state}
      end

      def handle_info(:warmer_tick, state) do
        state = execute(state)
        Process.send_after(self(), :warmer_tick, 1000)
        {:noreply, state}
      end
    end
  end
end

defmodule Argus.Test.Soundness.Mailbox.NolinkWarmer do
  @moduledoc false
  # The program's warmer starts an unlinked task from its own execute/1,
  # in the warmer's process: the task's reply and its :DOWN arrive in a
  # handle_info/2 that takes only the library's tick. The first refresh
  # crashes the warmer with a FunctionClauseError.
  use Argus.Test.Soundness.Mailbox.Lib.Warmer

  @impl Argus.Test.Soundness.Mailbox.Lib.Warmer
  def execute(state) do
    Task.Supervisor.async_nolink(Argus.Test.Soundness.Mailbox.TaskSup, fn -> refresh() end)
    state
  end

  defp refresh, do: :ok
end

defmodule Argus.Test.Soundness.Mailbox.MonitorWarmer do
  @moduledoc false
  # The program's warmer monitors the process it refreshes from, in its
  # own execute/1: the :DOWN lands in the library's handle_info/2.
  use Argus.Test.Soundness.Mailbox.Lib.Warmer

  @impl Argus.Test.Soundness.Mailbox.Lib.Warmer
  def execute(state) do
    Process.monitor(state.source)
    state
  end
end

defmodule Argus.Test.Soundness.Mailbox.Session do
  @moduledoc false
  use GenServer
  def start_link(user), do: GenServer.start_link(__MODULE__, user)
  @impl true
  def init(user), do: {:ok, user}
end

defmodule Argus.Test.Soundness.Mailbox.Sessions do
  @moduledoc false
  use DynamicSupervisor
  def start_link(o), do: DynamicSupervisor.start_link(__MODULE__, o, name: __MODULE__)
  @impl true
  def init(_), do: DynamicSupervisor.init(strategy: :one_for_one)

  # Start the user's session, or find the one already running.
  def start_session(user) do
    case DynamicSupervisor.start_child(__MODULE__, {Argus.Test.Soundness.Mailbox.Session, user}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end
end

defmodule Argus.Test.Soundness.Mailbox.Tracker do
  @moduledoc false
  # Every join monitors the user's (shared, long-lived) session again and
  # drops the ref: N joins leave N monitors, none releasable, and N
  # :DOWNs when it finally stops.
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:join, user}, _from, state) do
    {:ok, pid} = Argus.Test.Soundness.Mailbox.Sessions.start_session(user)
    Process.monitor(pid)
    {:reply, {:ok, pid}, Map.update(state, user, 1, &(&1 + 1))}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, Map.delete(state, pid)}
end

defmodule Argus.Test.Soundness.Mailbox.MixedCallers do
  @moduledoc false
  # One private helper returns the monitor ref. handle_call keeps it and
  # demonitors on :unwatch; handle_cast (a fire-and-forget subscribe)
  # throws it away: every cast leaves a monitor nothing can release.
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:watch, pid}, _from, state) do
    ref = watch(pid)
    {:reply, :ok, Map.put(state, pid, ref)}
  end

  def handle_call({:unwatch, pid}, _from, state) do
    case Map.pop(state, pid) do
      {nil, state} ->
        {:reply, :ok, state}

      {ref, state} ->
        Process.demonitor(ref, [:flush])
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_cast({:watch, pid}, state) do
    watch(pid)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, Map.delete(state, pid)}

  defp watch(pid), do: Process.monitor(pid)
end

defmodule Argus.Test.Soundness.Mailbox.MapDropped2 do
  @moduledoc false
  # Enum.map where Enum.each was meant: the list of refs is thrown away.
  # The server does demonitor the one ref it keeps (:watch_one), so the
  # module-wide "never demonitors" heuristic does not stand in.
  use GenServer

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:watch_all, pids}, _from, state) do
    Enum.map(pids, fn pid -> Process.monitor(pid) end)
    {:reply, :ok, state}
  end

  def handle_call({:watch_one, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, Map.put(state, pid, ref)}
  end

  def handle_call({:unwatch, pid}, _from, state) do
    {ref, state} = Map.pop(state, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, Map.delete(state, pid)}
end

defmodule Argus.Test.Soundness.Mailbox.EnvelopeSystem2 do
  @moduledoc false
  # A 2-tuple tagged :system is NOT the sys envelope ({:system, from,
  # req} is): a gen_server hands it to handle_info/2, which has no clause
  # for it. A FunctionClauseError on every reload.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def reload(pid), do: send(pid, {:system, :reload})

  def run do
    {:ok, pid} = start_link([])
    reload(pid)
  end

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Mailbox.TwoStateInfo do
  @moduledoc false
  # handle_event_function: the only :info clause names the :connected
  # state. The :ping timer is armed in :disconnected, and an :info there
  # has no clause: a FunctionClauseError.
  @behaviour :gen_statem

  def start_link, do: :gen_statem.start_link(__MODULE__, [], [])

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(_), do: {:ok, :disconnected, %{}, [{:next_event, :internal, :connect}]}

  @impl true
  def handle_event(:internal, :connect, :disconnected, data) do
    Process.send_after(self(), :ping, 1000)
    {:keep_state, data}
  end

  def handle_event(:info, msg, :connected, data), do: {:keep_state, Map.put(data, :last, msg)}

  def handle_event({:call, from}, :go, :disconnected, data),
    do: {:next_state, :connected, data, [{:reply, from, :ok}]}
end

defmodule Argus.Test.Soundness.Mailbox.ListsMapDropped do
  @moduledoc "lists:map/2 of monitors, the refs dropped (item 26's neighbour)."
  use GenServer
  @impl true
  def init(_), do: {:ok, %{}}
  @impl true
  def handle_call({:watch_all, pids}, _from, state) do
    :lists.map(fn pid -> Process.monitor(pid) end, pids)
    {:reply, :ok, state}
  end

  def handle_call({:watch_one, pid}, _from, state),
    do: {:reply, :ok, Map.put(state, pid, Process.monitor(pid))}

  def handle_call({:unwatch, pid}, _from, state) do
    {ref, state} = Map.pop(state, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, Map.delete(state, pid)}
end

defmodule Argus.Test.Soundness.Mailbox.EnvelopeCast3 do
  @moduledoc "A {:\"$gen_cast\", a, b} 3-tuple is no cast envelope (item 33's neighbour)."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def run do
    {:ok, pid} = start_link([])
    send(pid, {:"$gen_cast", :refresh, :now})
  end

  @impl true
  def init(opts), do: {:ok, opts}
  @impl true
  def handle_info(:tick, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Mailbox.TaskFactories do
  @moduledoc false
  # Functions that start a linked task and do not hand it back on every
  # way out: its reply is never awaited, and each call leaves one in the
  # caller's mailbox (or crashes it with the task).

  # Handed back on one way out, dropped on the other.
  def maybe(fun, keep?) do
    task = Task.async(fun)
    if keep?, do: task, else: :dropped
  end

  # Two tasks, one handed back: the first is nobody's.
  def two(first, second) do
    _ = Task.async(first)
    Task.async(second)
  end

  # The task's pid handed back, not the task: nothing can await it.
  def pid_only(fun), do: Task.async(fun).pid
end
