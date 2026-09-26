defmodule Probe.R2.G5.NoprocAndReexit do
  # The second clause takes every tuple reason only to exit with it
  # again: a peer that stops mid-call ({:shutdown, _}) still crashes the
  # caller, exactly as if the clause were not there.
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    try do
      GenServer.call(parent, {:child_mount, self()})
    catch
      :exit, {:noproc, _} -> {:error, :client_down}
      :exit, {reason, _} -> exit(reason)
    end
  end
end

defmodule Probe.R2.G5.NoprocAndAllButShutdown do
  # The second clause takes every tuple reason except the one the rule
  # asks about: {:shutdown, _} is exactly what it lets through.
  use GenServer

  def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

  @impl true
  def init(parent), do: {:ok, parent}

  @impl true
  def handle_info(:sync, parent) do
    _ = sync_with_parent(parent)
    {:noreply, parent}
  end

  defp sync_with_parent(parent) do
    try do
      GenServer.call(parent, {:child_mount, self()})
    catch
      :exit, {:noproc, _} -> {:error, :client_down}
      :exit, {reason, _} when reason != :shutdown -> {:error, reason}
    end
  end
end

defmodule S2c.Catch.ReraiseErlang do
  # The open clause hands the reason on with :erlang.raise/3.
  use GenServer
  def start_link(p), do: GenServer.start_link(__MODULE__, p)
  @impl true
  def init(p), do: {:ok, p}
  @impl true
  def handle_info(:sync, p) do
    _ = sync(p)
    {:noreply, p}
  end

  defp sync(p) do
    try do
      GenServer.call(p, :ping)
    catch
      :exit, {:noproc, _} -> {:error, :down}
      :exit, {_, _} = reason -> :erlang.raise(:exit, reason, __STACKTRACE__)
    end
  end
end

defmodule S2c.Catch.ShutdownReexit do
  # A clause for {:shutdown, _} that exits with it again.
  use GenServer
  def start_link(p), do: GenServer.start_link(__MODULE__, p)
  @impl true
  def init(p), do: {:ok, p}
  @impl true
  def handle_info(:sync, p) do
    _ = sync(p)
    {:noreply, p}
  end

  defp sync(p) do
    try do
      GenServer.call(p, :ping)
    catch
      :exit, {:noproc, _} -> {:error, :down}
      :exit, {:shutdown, _} = reason -> exit(reason)
    end
  end
end

defmodule S2c.Catch.AnyExitReexit do
  # Every exit reason, exited with again.
  use GenServer
  def start_link(p), do: GenServer.start_link(__MODULE__, p)
  @impl true
  def init(p), do: {:ok, p}
  @impl true
  def handle_info(:sync, p) do
    _ = sync(p)
    {:noreply, p}
  end

  defp sync(p) do
    try do
      GenServer.call(p, :ping)
    catch
      :exit, {:noproc, _} -> {:error, :down}
      :exit, reason -> exit(reason)
    end
  end
end

defmodule S2c.Catch.OpenKept do
  # Negative: the open clause keeps what it catches (brod's shape).
  use GenServer
  def start_link(p), do: GenServer.start_link(__MODULE__, p)
  @impl true
  def init(p), do: {:ok, p}
  @impl true
  def handle_info(:sync, p) do
    _ = sync(p)
    {:noreply, p}
  end

  defp sync(p) do
    try do
      GenServer.call(p, :ping)
    catch
      :exit, {:noproc, _} -> {:error, :down}
      :exit, {reason, _} -> {:error, reason}
    end
  end
end
