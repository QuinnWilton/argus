defmodule Argus.Test.Fixtures.BareRescue do
  @moduledoc false

  # Uses try/catch which catches all exception classes without filtering.
  # Unlike rescue (which only catches errors), catch catches everything.
  def swallow_all(f) do
    try do
      f.()
    catch
      _, _ -> :ok
    end
  end
end

defmodule Argus.Test.Fixtures.FilteredRescue do
  @moduledoc false

  # rescue _ -> adds a class test for :error and re-raises non-error.
  def handle_specific(f) do
    try do
      f.()
    rescue
      _ -> :caught
    end
  end
end

defmodule Argus.Test.Fixtures.TrapExitModule do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(_, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.ExitCaller do
  @moduledoc false

  def kill(pid), do: Process.exit(pid, :kill)
  def exit_self, do: :erlang.exit(:normal)
end

defmodule Argus.Test.Fixtures.IgnoredResultModule do
  @moduledoc false

  def ignored_start do
    GenServer.start_link(Argus.Test.Fixtures.PlainModule, [])
    :ok
  end

  def checked_start do
    case GenServer.start_link(Argus.Test.Fixtures.PlainModule, []) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "failed: #{inspect(reason)}"
    end
  end
end

defmodule Argus.Test.Fixtures.RawTrapExit do
  @moduledoc false

  # Hand-rolled :gen_server (no `use GenServer`): traps exits but defines
  # no handle_info, so {:EXIT, ...} messages crash the server. `use
  # GenServer` modules always compile in a default handle_info, which is
  # why this rule can only fire for raw behaviour modules.
  @behaviour :gen_server

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(_msg, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.ExitingServer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  # Process.exit inside a callback bypasses OTP shutdown protocol.
  @impl true
  def handle_cast({:kill, pid}, state) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end
end
