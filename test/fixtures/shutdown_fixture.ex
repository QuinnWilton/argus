defmodule Argus.Test.Fixtures.Shutdown do
  @moduledoc """
  Fixtures for the shutdown-safety analysis.

  The pairs matter more than the positives here. Every module that does
  cleanup has a twin that does the same cleanup while trapping exits, so a
  test can tell "found the cleanup" apart from "found the missing trap" —
  the second is the whole claim, and an analysis that reported both would be
  reporting nothing.
  """

  defmodule Leaks do
    @moduledoc "The bug: durable cleanup, no trap_exit."
    @behaviour GenServer

    def init(_), do: {:ok, %{path: "/tmp/leaks"}}

    @impl GenServer
    def terminate(_reason, state) do
      File.write!(state.path, "final")
      :ok
    end
  end

  defmodule Traps do
    @moduledoc "The same cleanup, reached because the module traps exits."
    @behaviour GenServer

    def init(_) do
      Process.flag(:trap_exit, true)
      {:ok, %{path: "/tmp/traps"}}
    end

    @impl GenServer
    def terminate(_reason, state) do
      File.write!(state.path, "final")
      :ok
    end
  end

  defmodule LeaksIndirect do
    @moduledoc "Same as Leaks, but the write is a call or two down."
    @behaviour GenServer

    def init(_), do: {:ok, %{path: "/tmp/indirect"}}

    @impl GenServer
    def terminate(_reason, state) do
      flush(state)
      :ok
    end

    def flush(state), do: persist(state.path)
    def persist(path), do: File.write!(path, "final")
  end

  defmodule LogsOnly do
    @moduledoc """
    Logging is not cleanup. A terminate/2 that only announces itself loses
    nothing by never running, which is why logging is its own effect
    category rather than sharing `:io` with file writes.
    """
    @behaviour GenServer

    require Logger

    def init(_), do: {:ok, %{}}

    @impl GenServer
    def terminate(reason, _state) do
      Logger.info("shutting down: #{inspect(reason)}")
      :ok
    end
  end

  defmodule ReadsOnly do
    @moduledoc """
    A read has nothing to lose by being skipped — the same reasoning that
    keeps `Application.get_env/2` out of the transaction analysis.
    """
    @behaviour GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl GenServer
    def terminate(_reason, _state) do
      _ = System.tmp_dir!()
      _ = Path.expand("~/x")
      :ok
    end
  end

  defmodule Unclear do
    @moduledoc """
    Cleanup the effect model cannot classify, which is where most real
    cleanup lives: a call into the application's own code.
    """
    @behaviour GenServer

    def init(_), do: {:ok, %{}}

    @impl GenServer
    def terminate(_reason, state) do
      Argus.Test.Fixtures.Shutdown.Lease.release(state)
      :ok
    end
  end

  defmodule UnclearTraps do
    @moduledoc "The same unclassified cleanup, but trapping."
    @behaviour GenServer

    @impl true
    def init(_) do
      Process.flag(:trap_exit, true)
      {:ok, %{}}
    end

    @impl GenServer
    def terminate(_reason, state) do
      Argus.Test.Fixtures.Shutdown.Lease.release(state)
      :ok
    end
  end

  defmodule Lease do
    @moduledoc false
    def release(_state), do: :ok
  end

  defmodule Truncatable do
    @moduledoc """
    Trapping, so terminate/2 is reached — but a network call has no bound
    of its own and the supervisor's shutdown timeout does.
    """
    @behaviour GenServer

    @impl true
    def init(_) do
      Process.flag(:trap_exit, true)
      {:ok, %{}}
    end

    @impl GenServer
    def terminate(_reason, _state) do
      :httpc.request(~c"http://registry/deregister")
      :ok
    end
  end

  defmodule CleansUpElsewhere do
    @moduledoc "Cleanup outside terminate/2 is not this analysis's business."
    @behaviour GenServer

    def init(_), do: {:ok, %{}}

    def handle_call(:stop, _from, state) do
      File.write!("/tmp/elsewhere", "final")
      {:stop, :normal, :ok, state}
    end
  end
end
