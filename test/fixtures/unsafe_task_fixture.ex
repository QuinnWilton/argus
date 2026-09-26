defmodule Argus.Test.Fixtures.LeakedTaskModule do
  @moduledoc false

  # Leaked: creates an async task but never awaits it.
  def fire_and_forget do
    Task.async(fn -> :heavy_work end)
    :ok
  end

  # Safe: creates and awaits the task.
  def safe_async do
    task = Task.async(fn -> :work end)
    Task.await(task)
  end
end

defmodule Argus.Test.Fixtures.GenServerTaskConsumer do
  @moduledoc false

  # GenServer that uses async_nolink and consumes the result via handle_info.
  # Should NOT be flagged by leaked_async_task.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  def dispatch_work(server), do: GenServer.cast(server, :dispatch)

  @impl true
  def handle_cast(:dispatch, state) do
    Task.Supervisor.async_nolink(state.task_sup, fn -> :work end)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, Map.put(state, :last_result, result)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end
end

defmodule Argus.Test.Fixtures.UncheckedStartChild do
  @moduledoc false

  # Unchecked: start_child result is ignored.
  def start_unchecked(sup) do
    Task.Supervisor.start_child(sup, fn -> :background end)
    :ok
  end

  # Checked: start_child result is pattern matched.
  def start_checked(sup) do
    case Task.Supervisor.start_child(sup, fn -> :background end) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  # Tail position: result propagated to caller.
  def start_tail(sup) do
    Task.Supervisor.start_child(sup, fn -> :background end)
  end
end

defmodule Argus.Test.Fixtures.SupervisedFireAndForget do
  @moduledoc false

  # Uses Task.Supervisor.async_nolink without await and without being
  # a GenServer. The supervisor manages the lifecycle — not a leak.
  def dispatch(sup) do
    Task.Supervisor.async_nolink(sup, fn -> :work end)
    :ok
  end
end

defmodule Argus.Test.Fixtures.TaskFactory do
  @moduledoc false

  # Task factory: async_nolink in tail position returns the task to the caller.
  # The caller is responsible for awaiting — not a leak.
  def async(sup, fun) do
    Task.Supervisor.async_nolink(sup, fun)
  end
end

# Phoenix.LiveView is a stub (test/fixtures/behaviour_stubs.ex): it is
# not a dependency of argus.
defmodule Argus.Test.Fixtures.LiveViewTaskConsumer do
  @moduledoc false

  # LiveView that dispatches async tasks and consumes results via handle_info.
  # Should NOT be flagged by leaked_async_task.
  @behaviour Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, socket}

  def render(assigns), do: assigns

  def handle_info({ref, _result}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, socket}
  end

  # This function creates an async task without awaiting.
  # Suppressed because LiveView consumes task messages via handle_info.
  def dispatch_task(socket) do
    Task.async(fn -> :work end)
    {:noreply, socket}
  end
end

defmodule Argus.Test.Fixtures.GenStatemTaskConsumer do
  @moduledoc false

  # gen_statem that dispatches async tasks and consumes results via handle_event/4.
  # Should NOT be flagged by leaked_async_task.
  @behaviour :gen_statem

  def callback_mode, do: :handle_event_function

  def init(state), do: {:ok, :idle, state}

  def handle_event(:info, {ref, _result}, _state, data) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:keep_state, data}
  end

  def handle_event(:internal, :dispatch, _state, data) do
    Task.async(fn -> :work end)
    {:keep_state, data}
  end
end

defmodule Argus.Test.Fixtures.TaskShutdownUser do
  @moduledoc false

  # Module that creates an async task and consumes it via Task.shutdown.
  # Should NOT be flagged by leaked_async_task.
  def run_with_timeout(fun) do
    task = Task.async(fun)
    Task.shutdown(task, :brutal_kill)
  end
end

defmodule Argus.Test.Fixtures.PlainTaskConsumer do
  @moduledoc false
  # Declares no behaviour argus knows: its handle_info/2 is invoked by a
  # hosting process (a Phoenix.Tracker shard, a hand-rolled loop) that
  # delegates messages to it. A clause headed by a reference takes the
  # task's reply. (It keeps the result: a clause that returned the state
  # unchanged, as the catch-all does, would compile into the catch-all,
  # which drops the reply.)

  def start_work(sup, work) do
    Task.Supervisor.async(sup, fn -> work.() end)
    :ok
  end

  def handle_info({ref, result}, state) when is_reference(ref),
    do: {:noreply, Map.put(state, :result, result)}

  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.YieldsLinkedTask do
  @moduledoc false
  # redix#317: yield_many's {:exit, _} branch is dead — the link kills the
  # caller before it runs.
  def fan_out(work) do
    tasks = Enum.map(work, fn item -> Task.async(fn -> item end) end)

    tasks
    |> Task.yield_many(1_000)
    |> Enum.map(fn
      {_task, {:ok, result}} -> {:ok, result}
      {_task, {:exit, reason}} -> {:error, reason}
      {task, nil} -> {:error, Task.shutdown(task, :brutal_kill)}
    end)
  end
end

defmodule Argus.Test.Fixtures.TrapsAndYields do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call(:work, _from, state) do
    task = Task.async(fn -> :work end)
    {:reply, Task.yield(task, 1_000), state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsButYieldsInClient do
  @moduledoc false
  # The server traps exits; its client function runs in its caller, which
  # the server's trap says nothing of. The yield there is the caller's.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def fetch(item) do
    task = Task.async(fn -> item end)
    Task.yield(task, 1_000)
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.LibraryPmap do
  @moduledoc false
  # ecto#2246: a parallel map in library code, linked to whoever calls it.
  def pmap(items, fun) do
    items
    |> Enum.map(fn item -> Task.async(fn -> fun.(item) end) end)
    # A call, not `&Task.await/1`: a captured function is a fun literal the
    # call graph does not follow, so it would read as never awaited.
    |> Enum.map(fn task -> Task.await(task) end)
  end
end

defmodule Argus.Test.Fixtures.PoolCallSupervisor do
  @moduledoc false
  # elixir-nodejs#45: the library's public call/2 lives in its `use
  # Supervisor` module and runs in whoever calls it. The task links to
  # that caller; a crashing worker takes it down, and a timed-out task's
  # late reply lands in its mailbox.
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)

  def call(fun, timeout) do
    task = Task.async(fn -> fun.() end)

    try do
      Task.await(task, timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
    end
  end
end

defmodule Argus.Test.Fixtures.ServerSideTaskAwait do
  @moduledoc false
  # Quiet: the task links to the server itself, in its own callback.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    task = Task.async(fn -> fun.() end)
    {:reply, Task.await(task), state}
  end
end
