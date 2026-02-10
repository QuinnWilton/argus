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

defmodule Argus.Test.Fixtures.TaskFactory do
  @moduledoc false

  # Task factory: async_nolink in tail position returns the task to the caller.
  # The caller is responsible for awaiting — not a leak.
  def async(sup, fun) do
    Task.Supervisor.async_nolink(sup, fun)
  end
end
