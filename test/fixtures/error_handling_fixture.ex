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

defmodule Argus.Test.Fixtures.ReifyingRescue do
  @moduledoc false

  # Catches all classes but reifies the exception into a returned value —
  # the caller sees the error, nothing is swallowed. Must NOT be flagged.
  def to_result(f) do
    try do
      f.()
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end

defmodule Argus.Test.Fixtures.ReraisingRescue do
  @moduledoc false

  # Catches all classes, runs cleanup, then re-raises with the original
  # stacktrace — compiles to the raw_raise opcode. Must NOT be flagged.
  def cleanup_and_reraise(f, cleanup) do
    try do
      f.()
    catch
      kind, reason ->
        cleanup.()
        :erlang.raise(kind, reason, __STACKTRACE__)
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

defmodule Argus.Test.Fixtures.StatemTrapExit do
  @moduledoc false
  @behaviour :gen_statem

  def callback_mode, do: :state_functions

  # Traps exits and has no handle_info — but delivers {:EXIT, ...} to its
  # state functions, which it handles. Must NOT be flagged
  # trap_exit_without_handler.
  def init(_args) do
    Process.flag(:trap_exit, true)
    {:ok, :idle, %{}}
  end

  def idle(:info, {:EXIT, _pid, _reason}, data), do: {:keep_state, data}
  def idle(_type, _content, data), do: {:keep_state, data}
end

defmodule Argus.Test.Fixtures.SelfCrashCallback do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state), do: {:ok, state}

  # exit/1 raises an exit in THIS process (let-it-crash on an impossible
  # state) — supervision-visible, not an imperative kill of another
  # process. Must NOT be flagged exit_in_callback.
  @impl true
  def handle_call(:bad, _from, _state) do
    exit(:impossible_state)
  end
end

defmodule Argus.Test.Fixtures.TrapsWithoutExitClause do
  @moduledoc """
  Traps exits and has a handle_info/2 — so it passes the "no handler"
  check — but no clause accepts {:EXIT, ...}. Bandit's HTTP/1 handler.
  """
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_info({:plug_conn, :sent}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.TrapsWithExitClause do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.MonitorsWithoutCatchall do
  @moduledoc "Monitors callers, handles only {:DOWN, ...}: anything else crashes it."
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    ref = Process.monitor(pid)
    {:reply, ref, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Fixtures.MonitorsWithCatchall do
  @moduledoc false
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:watch, {pid, _tag}, state) do
    ref = Process.monitor(pid)
    {:reply, ref, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}
end
