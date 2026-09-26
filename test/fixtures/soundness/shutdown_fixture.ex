defmodule Argus.Test.Soundness.Shutdown do
  @moduledoc """
  Real shutdown bugs a suppression once silenced, and the adversarial
  shapes beside each: `test/soundness/shutdown_test.exs` asserts the
  finding each must keep.
  """

  # ── A trapped exit nothing takes (review 2, item 9) ──────────────────
  # 98cfdb25 asked "no :EXIT handler" only of a listed GenServer: a
  # hand-rolled loop's own receive, and a server under an unlisted
  # wrapper, went unasked.

  defmodule Protocol do
    @moduledoc "A behaviour argus does not know, standing for ranch_protocol."
    @callback start_link(term(), term(), term()) :: {:ok, pid()}
  end

  defmodule TrapLoopFn do
    @moduledoc """
    A hand-rolled process: start_link spawns a closure that runs the
    loop. It traps exits, and its receive has no {:EXIT, _, _} clause:
    the linked parent's exit signal becomes a message nothing takes, so
    the process outlives its parent and the exit messages pile up.
    """
    def start_link(opts), do: {:ok, spawn_link(fn -> run(opts) end)}

    def put(pid, k, v), do: send(pid, {:put, k, v})

    def run(_opts) do
      Process.flag(:trap_exit, true)
      loop(%{})
    end

    defp loop(state) do
      receive do
        {:put, k, v} ->
          loop(Map.put(state, k, v))

        {:get, from, k} ->
          send(from, {:value, Map.get(state, k)})
          loop(state)
      end
    end
  end

  defmodule SetupThenLoop do
    @moduledoc """
    The trap in a setup helper, the loop the spawned fun runs after it:
    the process's receives are the fun's, not the helper's.
    """
    def start_link(opts) do
      {:ok,
       spawn_link(fn ->
         setup(opts)
         loop(%{})
       end)}
    end

    defp setup(_opts), do: Process.flag(:trap_exit, true)

    defp loop(state) do
      receive do
        {:put, k, v} -> loop(Map.put(state, k, v))
        :stop -> :ok
      end
    end
  end

  defmodule ProcLibLoop do
    @moduledoc """
    A proc_lib process under a behaviour argus does not know: its init
    traps, and its loop takes socket messages and no exit. What a spawn
    runs traps for its own process, which module_traps leaves out.
    """
    @behaviour Argus.Test.Soundness.Shutdown.Protocol

    @impl true
    def start_link(ref, transport, opts),
      do: {:ok, :proc_lib.spawn_link(__MODULE__, :init, [{ref, transport, opts}])}

    def init({_ref, _transport, opts}) do
      Process.flag(:trap_exit, true)
      loop(opts)
    end

    defp loop(opts) do
      receive do
        {:tcp, _sock, data} -> loop(Map.put(opts, :last, data))
        {:tcp_closed, _sock} -> :ok
      end
    end
  end

  defmodule ExitClauseLoop do
    @moduledoc "Quiet: the loop takes {:EXIT, ...}."
    def start_link, do: {:ok, spawn_link(fn -> run() end)}

    def run do
      Process.flag(:trap_exit, true)
      loop()
    end

    defp loop do
      receive do
        {:EXIT, _from, reason} ->
          exit(reason)

        {:work, from} ->
          send(from, :done)
          loop()
      end
    end
  end

  defmodule CatchAllLoop do
    @moduledoc "Quiet: the loop takes any message."
    def start_link, do: {:ok, spawn_link(fn -> run() end)}

    def run do
      Process.flag(:trap_exit, true)
      loop()
    end

    defp loop do
      receive do
        {:work, from} ->
          send(from, :done)
          loop()

        _other ->
          loop()
      end
    end
  end

  # ── What runs when a supervisor stops the process ──────────────────
  # The terminate/2 sibling rule read terminate/2's own tests on the
  # reason and took a helper that chooses by the reason it is handed to
  # run every clause: mnesia's servers were reported for
  # mnesia_monitor:terminate_proc/3, which waits on mnesia_monitor only in
  # its clause for reasons other than :shutdown. The reason is now
  # followed as a value; each narrowing has a positive beside it.

  defmodule Reason do
    @moduledoc """
    terminate/2 on a supervisor's stop runs with the reason `:shutdown`,
    the bare atom (supervisor.erl's `shutdown/1`, DynamicSupervisor's
    `terminate_children/2`). Every caller below traps exits and sits
    before the directory in the supervisor's list, so the shutdown stops
    the directory first: a call to it that runs for `:shutdown` is the
    bug, one that runs only for other reasons is not.
    """

    defmodule Directory do
      @moduledoc false
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      def unregister(who), do: GenServer.call(__MODULE__, {:unregister, who})

      @doc "Waits only for reasons other than :shutdown, as mnesia_monitor:terminate_proc/3 does."
      def farewell(who, reason) when reason != :shutdown,
        do: GenServer.call(__MODULE__, {:unregister, who})

      def farewell(_who, _reason), do: :ok

      @doc "Waits for :shutdown."
      def depart(who, :shutdown), do: GenServer.call(__MODULE__, {:unregister, who})
      def depart(_who, _reason), do: :ok

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call({:unregister, _who}, _from, state), do: {:reply, :ok, state}
    end

    defmodule Sup do
      @moduledoc false
      use Supervisor

      alias Argus.Test.Soundness.Shutdown.Reason, as: R

      @impl true
      def init(_opts) do
        Supervisor.init(
          [
            R.ShutdownClause,
            R.NotShutdown,
            R.NotShutdownExact,
            R.ShutdownTuple,
            R.NormalThenAny,
            R.HelperChooses,
            R.HelperShutdownClause,
            R.HelperOtherValue,
            R.Relay,
            R.RelayShutdownClause,
            R.ApiChooses,
            R.ApiShutdownClause,
            R.Directory
          ],
          strategy: :one_for_one
        )
      end
    end

    defmodule ShutdownClause do
      @moduledoc "Fires: the clause for :shutdown makes the call."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(:shutdown, _state), do: Directory.unregister(__MODULE__)
      def terminate(_reason, _state), do: :ok
    end

    defmodule NotShutdown do
      @moduledoc "Quiet: the clause that calls is guarded `reason != :shutdown`."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, _state) when reason != :shutdown, do: Directory.unregister(__MODULE__)
      def terminate(_reason, _state), do: :ok
    end

    defmodule NotShutdownExact do
      @moduledoc "Quiet: the clause that calls is guarded `reason !== :shutdown` (Erlang's `=/=`)."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, _state) when reason !== :shutdown,
        do: Directory.unregister(__MODULE__)

      def terminate(_reason, _state), do: :ok
    end

    defmodule ShutdownTuple do
      @moduledoc """
      Quiet: the clause that calls takes `{:shutdown, _}`, a reason the
      process stops itself with or a parent that is no supervisor passes.
      A supervisor's stop passes the bare atom, which takes the other
      clause.
      """
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate({:shutdown, _why}, _state), do: Directory.unregister(__MODULE__)
      def terminate(_reason, _state), do: :ok
    end

    defmodule NormalThenAny do
      @moduledoc "Fires: a clause for :normal, then a catch-all that calls and takes :shutdown."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(:normal, _state), do: :ok
      def terminate(_reason, _state), do: Directory.unregister(__MODULE__)
    end

    defmodule HelperChooses do
      @moduledoc "Quiet: terminate/2 hands the reason to a helper whose calling clause is :normal's."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, _state), do: leave(reason)

      defp leave(:normal), do: Directory.unregister(__MODULE__)
      defp leave(_reason), do: :ok
    end

    defmodule HelperShutdownClause do
      @moduledoc "Fires: the helper's clause for :shutdown makes the call."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, _state), do: leave(reason)

      defp leave(:shutdown), do: Directory.unregister(__MODULE__)
      defp leave(_reason), do: :ok
    end

    defmodule HelperOtherValue do
      @moduledoc """
      Fires: the helper that calls only for :normal is also handed a
      literal :normal on the stop, so its calling clause runs.
      """
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, state) do
        leave(reason)
        if state.final, do: leave(:normal), else: :ok
      end

      defp leave(:normal), do: Directory.unregister(__MODULE__)
      defp leave(_reason), do: :ok
    end

    defmodule Relay do
      @moduledoc "Quiet: the reason passes through a helper that does not test it to one whose calling clause is :normal's."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, state), do: relay(reason, state)

      defp relay(reason, state) do
        :ok = leave(reason)
        state
      end

      defp leave(:normal), do: Directory.unregister(__MODULE__)
      defp leave(_reason), do: :ok
    end

    defmodule RelayShutdownClause do
      @moduledoc "Fires: through the same relay, the calling clause is :shutdown's."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, state), do: relay(reason, state)

      defp relay(reason, state) do
        :ok = leave(reason)
        state
      end

      defp leave(:shutdown), do: Directory.unregister(__MODULE__)
      defp leave(_reason), do: :ok
    end

    defmodule ApiChooses do
      @moduledoc """
      Quiet: terminate/2 hands the reason to the directory's client API,
      which waits only for other reasons (mnesia's servers and
      mnesia_monitor:terminate_proc/3).
      """
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, _state), do: Directory.farewell(__MODULE__, reason)
    end

    defmodule ApiShutdownClause do
      @moduledoc "Fires: the client API it hands the reason to waits for :shutdown."
      use GenServer
      alias Argus.Test.Soundness.Shutdown.Reason.Directory

      @impl true
      def init(state) do
        Process.flag(:trap_exit, true)
        {:ok, state}
      end

      @impl true
      def terminate(reason, _state), do: Directory.depart(__MODULE__, reason)
    end
  end
end
