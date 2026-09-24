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

    @impl GenServer
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

    @impl GenServer
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

    @impl GenServer
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

    @impl GenServer
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

    @impl GenServer
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

defmodule Argus.Test.Fixtures.ShutdownSiblings do
  @moduledoc false

  defmodule Sup do
    @moduledoc false
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      children = [
        Argus.Test.Fixtures.ShutdownSiblings.Producer,
        Argus.Test.Fixtures.ShutdownSiblings.Watchman,
        Argus.Test.Fixtures.ShutdownSiblings.CarefulWatchman,
        Argus.Test.Fixtures.ShutdownSiblings.GuardedWatchman
      ]

      # oban's queue supervisor: the Producer crashing takes the Watchman
      # down with it, and the Watchman's terminate/2 calls the dead Producer.
      Supervisor.init(children, strategy: :rest_for_one)
    end
  end

  defmodule Producer do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def pause, do: GenServer.call(__MODULE__, :pause)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:pause, _from, state), do: {:reply, :ok, state}
  end

  defmodule Watchman do
    @moduledoc false
    # oban#21: pauses its sibling producer from terminate/2 while the
    # supervisor may already have stopped it.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def terminate(_reason, _state) do
      :ok = Argus.Test.Fixtures.ShutdownSiblings.Producer.pause()
    end
  end

  defmodule CarefulWatchman do
    @moduledoc false
    # Same shape, cast instead of call: nothing to wait on.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def terminate(_reason, _state) do
      GenServer.cast(Argus.Test.Fixtures.ShutdownSiblings.Producer, :pause)
    end
  end
end

defmodule Argus.Test.Fixtures.ForeignChildren do
  @moduledoc false

  defmodule LibraryTree do
    @moduledoc false
    # The library's own tree: owns the DynamicSupervisor.
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      children = [
        {DynamicSupervisor,
         name: Argus.Test.Fixtures.ForeignChildren.Pool, strategy: :one_for_one}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule AppTree do
    @moduledoc false
    # The user's tree: the manager lives here, its children over there.
    use Supervisor

    def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      children = [
        Argus.Test.Fixtures.ForeignChildren.Manager,
        Argus.Test.Fixtures.ForeignChildren.TidyManager
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule Worker do
    @moduledoc false
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule Manager do
    @moduledoc false
    # postgrex#763: starts connections under the library's supervisor and
    # never stops them when it goes down itself.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      {:ok, _} =
        DynamicSupervisor.start_child(
          Argus.Test.Fixtures.ForeignChildren.Pool,
          {Argus.Test.Fixtures.ForeignChildren.Worker, []}
        )

      {:ok, state}
    end
  end

  defmodule TidyManager do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_state) do
      Process.flag(:trap_exit, true)

      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Fixtures.ForeignChildren.Pool,
          {Argus.Test.Fixtures.ForeignChildren.Worker, []}
        )

      {:ok, %{child: pid}}
    end

    @impl true
    def terminate(_reason, %{child: pid}) do
      DynamicSupervisor.terminate_child(Argus.Test.Fixtures.ForeignChildren.Pool, pid)
    end
  end
end

defmodule Argus.Test.Fixtures.ForeignChildren.TaskTree do
  @moduledoc false
  # A library's tree owning a Task.Supervisor.
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [{Task.Supervisor, name: Argus.Test.Fixtures.ForeignChildren.TaskSup}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.ForeignChildren.TaskStarter do
  @moduledoc false
  # Starts tasks under the library's Task.Supervisor; they follow that
  # tree, not this process's.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(state) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Argus.Test.Fixtures.ForeignChildren.TaskSup, fn ->
        Process.sleep(:infinity)
      end)

    {:ok, state}
  end
end

defmodule Argus.Test.Fixtures.ShutdownSiblings.GuardedWatchman do
  @moduledoc false
  # oban's fix: the call survives the sibling being gone.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    try do
      Argus.Test.Fixtures.ShutdownSiblings.Producer.pause()
    catch
      :exit, _ -> :ok
    end
  end
end

defmodule Argus.Test.Fixtures.SiblingOrder do
  @moduledoc """
  Which sibling a terminate/2 may call depends on who the supervisor has
  already stopped: under any strategy, one started after the caller stops
  first on shutdown; under rest_for_one or one_for_all, one started
  before the caller is the one whose crash terminates it.
  """

  defmodule Directory do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def unregister(who), do: GenServer.call(__MODULE__, {:unregister, who})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:unregister, _who}, _from, state), do: {:reply, :ok, state}
  end

  defmodule Writer do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def terminate(_reason, _state) do
      :ok = Argus.Test.Fixtures.SiblingOrder.Directory.unregister(__MODULE__)
    end
  end

  defmodule CalleeStartsLater do
    @moduledoc "The writer first, the directory after: shutdown stops the directory first."
    use Supervisor

    @impl true
    def init(_opts) do
      Supervisor.init(
        [Argus.Test.Fixtures.SiblingOrder.Writer, Argus.Test.Fixtures.SiblingOrder.Directory],
        strategy: :one_for_one
      )
    end
  end

  defmodule CalleeStartsEarlier do
    @moduledoc "The directory first: shutdown stops the writer while the directory is up."
    use Supervisor

    @impl true
    def init(_opts) do
      Supervisor.init(
        [Argus.Test.Fixtures.SiblingOrder.Directory, Argus.Test.Fixtures.SiblingOrder.Writer],
        strategy: :one_for_one
      )
    end
  end

  defmodule CalleeEarlierRestForOne do
    @moduledoc "oban#21's shape: the directory crashing is why the writer is terminated."
    use Supervisor

    @impl true
    def init(_opts) do
      Supervisor.init(
        [Argus.Test.Fixtures.SiblingOrder.Directory, Argus.Test.Fixtures.SiblingOrder.Writer],
        strategy: :rest_for_one
      )
    end
  end

  defmodule CalleeEarlierUnknownStrategy do
    @moduledoc "The directory first, under a strategy chosen at runtime."
    use Supervisor

    @impl true
    def init(opts) do
      Supervisor.init(
        [Argus.Test.Fixtures.SiblingOrder.Directory, Argus.Test.Fixtures.SiblingOrder.Writer],
        strategy: Keyword.fetch!(opts, :strategy)
      )
    end
  end
end

defmodule Argus.Test.Fixtures.SiblingGuard do
  @moduledoc """
  Which try guards terminate/2's call to a sibling: the one whose
  protected region holds that call, or the call leading to the helper
  that makes it. The directory starts last, so shutdown stops it before
  any writer: every unguarded call is the bug.
  """

  defmodule Directory do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def unregister(who), do: GenServer.call(__MODULE__, {:unregister, who})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:unregister, _who}, _from, state), do: {:reply, :ok, state}
  end

  defmodule Sup do
    @moduledoc false
    use Supervisor

    alias Argus.Test.Fixtures.SiblingGuard, as: G

    @impl true
    def init(_opts) do
      Supervisor.init(
        [
          G.CallInside,
          G.TryElsewhere,
          G.HelperInside,
          G.HelperGuards,
          G.HelperTryElsewhere,
          G.ErrorOnly,
          G.NestedOuterExit,
          G.NestedAfterInner,
          G.NoprocInside,
          G.ClosureTryElsewhere,
          G.ClosureInside,
          G.RefTryElsewhere,
          G.Directory
        ],
        strategy: :one_for_one
      )
    end
  end

  defmodule CallInside do
    @moduledoc "The sibling call inside the exit-catching try: guarded."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      try do
        Directory.unregister(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defmodule TryElsewhere do
    @moduledoc "The try catches exits around another call; the sibling call follows its end."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      try do
        GenServer.stop(state, :normal)
      catch
        :exit, _ -> :ok
      end

      Directory.unregister(__MODULE__)
    end
  end

  defmodule HelperInside do
    @moduledoc "The call into the helper that makes the sibling call is inside the try."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      try do
        leave()
      catch
        :exit, _ -> :ok
      end
    end

    defp leave do
      :ok = Directory.unregister(__MODULE__)
      :left
    end
  end

  defmodule HelperGuards do
    @moduledoc "The helper has its own try around the sibling call."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      :ok = leave()
      :ok
    end

    defp leave do
      try do
        Directory.unregister(__MODULE__)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defmodule HelperTryElsewhere do
    @moduledoc "The helper's try covers another call; its sibling call is after the end."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      :ok = leave(state)
      :ok
    end

    defp leave(state) do
      try do
        GenServer.stop(state, :normal)
      catch
        :exit, _ -> :ok
      end

      Directory.unregister(__MODULE__)
    end
  end

  defmodule ErrorOnly do
    @moduledoc "The try around the sibling call catches only errors: the exit escapes."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      try do
        Directory.unregister(__MODULE__)
      catch
        :error, _ -> :ok
      end
    end
  end

  defmodule NestedOuterExit do
    @moduledoc "An inner try catches errors, the outer one exits: the call is inside both."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      try do
        try do
          Directory.unregister(__MODULE__)
        catch
          :error, _ -> :ok
        end
      catch
        :exit, _ -> :ok
      end
    end
  end

  defmodule NestedAfterInner do
    @moduledoc """
    The inner try catches exits around another call; the sibling call
    follows its end, still inside an outer try that catches only errors.
    """
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      try do
        try do
          GenServer.stop(state, :normal)
        catch
          :exit, _ -> :ok
        end

        Directory.unregister(__MODULE__)
      catch
        :error, _ -> :ok
      end
    end
  end

  defmodule NoprocInside do
    @moduledoc "The try around the sibling call takes the :noproc exit by name."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state) do
      try do
        Directory.unregister(__MODULE__)
      catch
        :exit, {:noproc, _} -> :ok
      end
    end
  end

  defmodule ClosureTryElsewhere do
    @moduledoc """
    The audit's shape: a try catches exits around an unrelated stop, and
    the sibling call is in a closure handed to Enum.each after its end.
    Nothing covers the Enum.each, so nothing catches the exit.
    """
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def terminate(_reason, state) do
      try do
        GenServer.stop(state.conn)
      catch
        :exit, _ -> :ok
      end

      Enum.each(state.peers, fn peer -> :ok = Directory.unregister(peer) end)
      File.close(state.log)
    end
  end

  defmodule ClosureInside do
    @moduledoc "The Enum.each that runs the closure is inside the exit-catching try."
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def terminate(_reason, state) do
      try do
        Enum.each(state.peers, fn peer -> :ok = Directory.unregister(peer) end)
      catch
        :exit, _ -> :ok
      end

      File.close(state.log)
    end
  end

  defmodule RefTryElsewhere do
    @moduledoc """
    The sibling's API handed as a function reference, after a try around
    another call: the Enum.each that runs it is not covered.
    """
    use GenServer

    alias Argus.Test.Fixtures.SiblingGuard.Directory

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def terminate(_reason, state) do
      try do
        GenServer.stop(state.conn)
      catch
        :exit, _ -> :ok
      end

      Enum.each(state.peers, &Directory.unregister/1)
      File.close(state.log)
    end
  end
end
