defmodule Argus.Test.Fixtures.Quiet do
  @moduledoc """
  Shapes that must stay quiet: the nearest non-bug neighbour of each rule
  added in the 2026-09 issue-mining pass. `Argus.Analyses.QuietShapesTest`
  runs every touched analysis over these and asserts nothing fires.
  """

  defmodule SharedService do
    @moduledoc false
    # A DynamicSupervisor offering its own start API: children started
    # through it belong to its tree by design, whoever asks.
    use DynamicSupervisor

    def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

    def start_server(arg) do
      DynamicSupervisor.start_child(__MODULE__, {Argus.Test.Fixtures.Quiet.Server, arg})
    end

    @impl true
    def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
  end

  defmodule Server do
    @moduledoc false
    use GenServer

    def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

    @impl true
    def init(arg), do: {:ok, arg}
  end

  defmodule ServiceClient do
    @moduledoc false
    # Asks the shared service for a server from init/1: not a foreign start.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(arg) do
      {:ok, pid} = Argus.Test.Fixtures.Quiet.SharedService.start_server(arg)
      {:ok, %{server: pid}}
    end
  end

  defmodule PostponingStatem do
    @moduledoc false
    # A call clause that postpones the event answers it later.
    @behaviour :gen_statem

    def start_link(_opts), do: :gen_statem.start_link(__MODULE__, [], [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(_), do: {:ok, :connecting, %{}}

    def connecting({:call, _from}, :fetch, _data), do: {:keep_state_and_data, [:postpone]}
    def connecting(:info, :connected, data), do: {:next_state, :ready, data}

    def ready({:call, from}, :fetch, data), do: {:keep_state, data, [{:reply, from, :ok}]}
  end

  defmodule ServerAwaits do
    @moduledoc false
    # Task.async inside a GenServer callback is linked to the server, which
    # is exactly the process that awaits it.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:compute, x}, _from, state) do
      task = Task.async(fn -> x * 2 end)
      {:reply, Task.await(task), state}
    end
  end

  defmodule TransientConsumers do
    @moduledoc false
    use ConsumerSupervisor

    def start_link(opts), do: ConsumerSupervisor.start_link(__MODULE__, opts)

    @impl true
    def init(_opts) do
      children = [
        %{
          id: Argus.Test.Fixtures.Quiet.Server,
          start: {Argus.Test.Fixtures.Quiet.Server, :start_link, []},
          restart: :transient
        }
      ]

      ConsumerSupervisor.init(children, strategy: :one_for_one)
    end
  end

  defmodule CleanupManager do
    @moduledoc false
    # Monitors a permanent dynamic child but only forgets it on :DOWN —
    # the supervisor is the one restart authority.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:connect, _from, state) do
      {:ok, pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Fixtures.Quiet.SharedService,
          {Argus.Test.Fixtures.Quiet.Server, []}
        )

      ref = Process.monitor(pid)
      {:reply, :ok, Map.put(state, ref, pid)}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      {:noreply, Map.delete(state, ref)}
    end
  end

  defmodule OwnStateAfterStart do
    @moduledoc false
    # Work after Supervisor.start_link that touches nothing shared.
    def start_link(config) do
      {:ok, pid} =
        Supervisor.start_link([Argus.Test.Fixtures.Quiet.Server], strategy: :one_for_one)

      {:ok, pid, summarize(config)}
    end

    defp summarize(config), do: Map.take(config, [:name])
  end

  defmodule CatchesEveryExit do
    @moduledoc false
    use GenServer

    def start_link(parent), do: GenServer.start_link(__MODULE__, parent)

    @impl true
    def init(parent), do: {:ok, parent}

    @impl true
    def handle_info(:sync, parent) do
      _ = sync_with_parent(parent)
      {:noreply, parent}
    end

    # The timed call above can leave a late reply; absorb it.
    def handle_info(_other, parent), do: {:noreply, parent}

    defp sync_with_parent(parent) do
      try do
        GenServer.call(parent, {:child_mount, self()})
      catch
        _kind, reason -> {:error, reason}
      end
    end
  end

  defmodule ErpcRescueAll do
    @moduledoc false
    # No case on the reason: every ErlangError becomes a value.
    def call(node, mod, fun, args) do
      {:ok, :erpc.call(node, mod, fun, args, 5000)}
    rescue
      e in ErlangError -> {:error, e}
    end
  end

  defmodule RescueAllReader do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key) do
      :ets.lookup(:quiet_rescue_all, key)
    rescue
      _ -> []
    end

    @impl true
    def init(_opts) do
      :ets.new(:quiet_rescue_all, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule BoundedReceive do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(parent) do
      send(parent, {:ready, self()})

      receive do
        {:go, config} -> {:ok, config}
      after
        5_000 -> {:stop, :no_go}
      end
    end
  end

  defmodule TimerWithCatchAll do
    @moduledoc false
    # A late-message source and a handle_info that absorbs the unexpected.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state) do
      Process.send_after(self(), :tick, 1_000)
      {:ok, state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
    def handle_info(_other, state), do: {:noreply, state}
  end

  defmodule UnrelatedMonitorRestarter do
    @moduledoc false
    # Monitors one process (a notifier it looks up) and restarts another
    # kind of child from a signal (Oban.Queues): two facts about two
    # processes, not two restart authorities over one.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, connect_notifier(state)}

    @impl true
    def handle_info({:signal, :start_queue, opts}, state) do
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          Argus.Test.Fixtures.Quiet.SharedService,
          {Argus.Test.Fixtures.Quiet.Server, opts}
        )

      {:noreply, state}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{notifier_ref: ref} = state) do
      {:noreply, connect_notifier(state)}
    end

    def handle_info(_other, state), do: {:noreply, state}

    defp connect_notifier(state) do
      case Process.whereis(:quiet_notifier) do
        nil -> state
        pid -> Map.put(state, :notifier_ref, Process.monitor(pid))
      end
    end
  end

  defmodule GenericTimeoutStatem do
    @moduledoc false
    # Arms a generic timeout and handles it; also builds a {:timeout, ref,
    # payload} tuple to send (DBConnection.Connection's timer message). No
    # event timeout is armed.
    @behaviour :gen_statem

    def start_link(_opts), do: :gen_statem.start_link(__MODULE__, [], [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(_), do: {:ok, :disconnected, %{backoff: 100}}

    @impl true
    def handle_event(:internal, :connect, :disconnected, data) do
      {:keep_state, data, {{:timeout, :backoff}, data.backoff, nil}}
    end

    def handle_event({:timeout, :backoff}, _content, :disconnected, data) do
      {:next_state, :connecting, data, {:next_event, :internal, :attempt}}
    end

    def handle_event(:internal, :attempt, :connecting, data) do
      ref = make_ref()
      send(self(), {:timeout, ref, {__MODULE__, self(), data.backoff}})
      {:next_state, :connected, Map.put(data, :timer, ref)}
    end

    def handle_event(:info, {:timeout, ref, {__MODULE__, _, _}}, :connected, %{timer: ref} = data) do
      {:keep_state, Map.delete(data, :timer)}
    end

    def handle_event(:info, _msg, _state, _data), do: :keep_state_and_data
  end

  defmodule ClockInTerminate do
    @moduledoc false
    # terminate/2 timestamps and logs; nothing durable, so nothing is lost
    # when a supervisor shutdown skips it.
    use GenServer
    require Logger

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, Map.put(state, :started, System.monotonic_time(:millisecond))}

    @impl true
    def terminate(_reason, state) do
      elapsed = System.monotonic_time(:millisecond) - state.started
      Logger.debug("ran for #{elapsed}ms")
    end
  end
end
