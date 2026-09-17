defmodule Argus.Test.Fixtures.Hypothesized do
  @moduledoc """
  The bug classes hypothesized after the 2026-09 issue-mining pass and
  validated against closed issues: one positive and its nearest quiet
  neighbour per rule. `Argus.Analyses.HypothesizedShapesTest` pins both
  sides.
  """

  # ── rpc results ──────────────────────────────────────────────────────

  defmodule RpcCaseNoBadrpc do
    @moduledoc false
    # rabbitmq-cli#193, phoenix_live_dashboard#218: a node that is gone
    # answers {:badrpc, _}, which no clause takes.
    def status(node) do
      case :rpc.call(node, :mnesia, :system_info, [:running_db_nodes]) do
        nodes when is_list(nodes) -> {:ok, nodes}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule RpcCaseWithBadrpc do
    @moduledoc false
    def status(node) do
      case :rpc.call(node, :mnesia, :system_info, [:running_db_nodes]) do
        {:badrpc, reason} -> {:error, reason}
        nodes when is_list(nodes) -> {:ok, nodes}
      end
    end
  end

  defmodule RpcBoolean do
    @moduledoc false
    # horde before 30bb1a1: {:badrpc, :nodedown} is truthy.
    def alive?(pid) do
      n = node(pid)
      Enum.member?(Node.list(), n) && :rpc.call(n, Process, :alive?, [pid])
    end
  end

  defmodule ErpcBooleanNoRescue do
    @moduledoc false
    def alive?(pid) do
      n = node(pid)
      Enum.member?(Node.list(), n) && :erpc.call(n, Process, :alive?, [pid])
    end
  end

  defmodule ErpcBooleanRescued do
    @moduledoc false
    # horde's fix.
    def alive?(pid) do
      n = node(pid)
      Enum.member?(Node.list(), n) && :erpc.call(n, Process, :alive?, [pid])
    rescue
      e in ErlangError ->
        case e.original do
          {:erpc, :noconnection} -> false
          other -> reraise ErlangError, [original: other], __STACKTRACE__
        end
    end
  end

  # ── timers ───────────────────────────────────────────────────────────

  defmodule TimerCancelNoFlush do
    @moduledoc false
    # beam-bots/bb#214, nebulex's generation heartbeat: cancel, re-arm a
    # bare :tick, and a delivered :tick is handled as the new one.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      Process.cancel_timer(state.timer)
      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    defp arm(interval), do: Process.send_after(self(), :tick, interval)
  end

  defmodule TimerCancelWithFlush do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      Process.cancel_timer(state.timer)

      receive do
        :tick -> :ok
      after
        0 -> :ok
      end

      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    defp arm(interval), do: Process.send_after(self(), :tick, interval)
  end

  defmodule TimerCancelBlockingFlush do
    @moduledoc false
    # The idiom from the cancel_timer/1 docs: a blocking receive, taken
    # only when the timer had already fired.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      if Process.cancel_timer(state.timer) == false do
        receive do
          :tick -> :ok
        end
      end

      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    defp arm(interval), do: Process.send_after(self(), :tick, interval)
  end

  defmodule TimerCancelWrongFlush do
    @moduledoc false
    # A receive that drains some other message is no flush for :tick.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      Process.cancel_timer(state.timer)

      receive do
        :drain -> :ok
      after
        0 -> :ok
      end

      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}
    def handle_info(:drain, state), do: {:noreply, state}

    defp arm(interval), do: Process.send_after(self(), :tick, interval)
  end

  defmodule TwoTimers do
    @moduledoc false
    # Cancels the poll timer (armed once, in init) and arms the tick
    # timer: different refs, different messages, and nothing re-arms
    # :poll, so nothing is stale.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval),
      do: {:ok, %{interval: interval, poll: Process.send_after(self(), :poll, 60_000), tick: nil}}

    @impl true
    def handle_call(:stop_polling, _from, state) do
      Process.cancel_timer(state.poll)
      {:reply, :ok, %{state | poll: nil, tick: Process.send_after(self(), :tick, state.interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
    def handle_info(:poll, state), do: {:noreply, state}
  end

  defmodule TimerWithRef do
    @moduledoc false
    # The message carries the ref; a stale one does not match the state.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      Process.cancel_timer(state.timer)
      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info({:tick, ref}, %{timer: ref} = state),
      do: {:noreply, %{state | timer: arm(state.interval)}}

    def handle_info({:tick, _stale}, state), do: {:noreply, state}

    defp arm(interval) do
      ref = make_ref()
      Process.send_after(self(), {:tick, ref}, interval)
      ref
    end
  end

  defmodule TimerForwarded do
    @moduledoc false
    # nebulex's generation heartbeat: the message is a parameter of the
    # arming helper, filled with a literal by its callers.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: start_timer(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      {:reply, :ok, %{state | interval: interval, timer: start_timer(interval, state.timer)}}
    end

    @impl true
    def handle_info(:heartbeat, state),
      do: {:noreply, %{state | timer: start_timer(state.interval, nil, :heartbeat)}}

    defp start_timer(time, ref \\ nil, event \\ :heartbeat) do
      _ = if ref, do: Process.cancel_timer(ref)
      Process.send_after(self(), event, time)
    end
  end

  defmodule TimerHelper do
    @moduledoc false
    # bb#214: a struct that arms and cancels ticks for whichever process
    # drives it; not a process itself.
    defstruct [:tick_ref, :period]

    def arm(%__MODULE__{period: period} = loop),
      do: %{loop | tick_ref: Process.send_after(self(), :tick, period)}

    def cancel(%__MODULE__{tick_ref: nil} = loop), do: loop

    def cancel(%__MODULE__{tick_ref: ref} = loop) do
      Process.cancel_timer(ref)
      %{loop | tick_ref: nil}
    end
  end

  defmodule TimerForOther do
    @moduledoc false
    # Arms timers for another process: its mailbox is not this one to flush.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(target), do: {:ok, %{target: target, timer: nil}}

    @impl true
    def handle_call({:schedule, ms}, _from, state) do
      if state.timer, do: Process.cancel_timer(state.timer)
      {:reply, :ok, %{state | timer: Process.send_after(state.target, :tick, ms)}}
    end
  end

  # ── async_nolink ─────────────────────────────────────────────────────

  defmodule NolinkPartialInfo do
    @moduledoc false
    # archethic-node#1306: the task's reply and :DOWN land in a handle_info
    # that knows other messages only.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(sup), do: {:ok, %{sup: sup}}

    @impl true
    def handle_cast({:run, work}, state) do
      Task.Supervisor.async_nolink(state.sup, fn -> work.() end)
      {:noreply, state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule NolinkBothClauses do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(sup), do: {:ok, %{sup: sup}}

    @impl true
    def handle_cast({:run, work}, state) do
      Task.Supervisor.async_nolink(state.sup, fn -> work.() end)
      {:noreply, state}
    end

    @impl true
    def handle_info({ref, _result}, state) when is_reference(ref) do
      Process.demonitor(ref, [:flush])
      {:noreply, state}
    end

    def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule NolinkCollected do
    @moduledoc false
    # Collected where it is started: nothing reaches handle_info.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(sup), do: {:ok, %{sup: sup}}

    @impl true
    def handle_call({:run, work}, _from, state) do
      task = Task.Supervisor.async_nolink(state.sup, fn -> work.() end)
      {:reply, Task.yield(task, 5_000) || Task.shutdown(task), state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  # ── connect in init ──────────────────────────────────────────────────

  defmodule ConnectInInit do
    @moduledoc false
    # tortoise#46: an unreachable broker at boot crash-loops the child and
    # takes the tree down.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init({host, port}) do
      case :gen_tcp.connect(host, port, [:binary, active: false]) do
        {:ok, sock} -> {:ok, %{sock: sock}}
        {:error, reason} -> {:stop, reason}
      end
    end
  end

  defmodule ConnectWithBackoff do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init({host, port}) do
      {:ok, %{host: host, port: port, sock: nil, backoff: 100}, {:continue, :connect}}
    end

    @impl true
    def handle_continue(:connect, state), do: {:noreply, connect(state)}

    @impl true
    def handle_info(:connect, state), do: {:noreply, connect(state)}

    defp connect(state) do
      case :gen_tcp.connect(state.host, state.port, [:binary, active: false]) do
        {:ok, sock} ->
          %{state | sock: sock}

        {:error, _reason} ->
          Process.send_after(self(), :connect, state.backoff)
          %{state | backoff: min(state.backoff * 2, 30_000)}
      end
    end
  end

  defmodule ConnectWithGenericBackoff do
    @moduledoc false
    # Postgrex.ReplicationConnection: a gen_statem that connects in init
    # and re-arms through a generic timeout.
    @behaviour :gen_statem

    def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init({host, port}) do
      case handle_event(:internal, :connect, :disconnected, %{host: host, port: port}) do
        {:next_state, state, data} -> {:ok, state, data}
        {:keep_state, data, actions} -> {:ok, :disconnected, data, actions}
      end
    end

    @impl true
    def handle_event({:timeout, :backoff}, nil, :disconnected, data),
      do: {:keep_state, data, {:next_event, :internal, :connect}}

    def handle_event(:internal, :connect, :disconnected, data) do
      case :gen_tcp.connect(data.host, data.port, [:binary, active: false]) do
        {:ok, sock} -> {:next_state, :connected, Map.put(data, :sock, sock)}
        {:error, _reason} -> {:keep_state, data, {{:timeout, :backoff}, 500, nil}}
      end
    end
  end

  # ── a callback stops a sibling ───────────────────────────────────────

  defmodule SiblingStop do
    @moduledoc false

    defmodule Sup do
      @moduledoc false
      use Supervisor

      def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_opts) do
        children = [
          Argus.Test.Fixtures.Hypothesized.SiblingStop.Workers,
          Argus.Test.Fixtures.Hypothesized.SiblingStop.Coordinator
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    defmodule Workers do
      @moduledoc false
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      # The sibling's own stop API.
      def stop, do: GenServer.stop(__MODULE__, :normal)

      @impl true
      def init(state), do: {:ok, state}
    end

    defmodule Coordinator do
      @moduledoc false
      # horde#193: on quorum loss the coordinator stops its sibling.
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_info(:quorum_lost, state) do
        :ok = Argus.Test.Fixtures.Hypothesized.SiblingStop.Workers.stop()
        {:noreply, state}
      end
    end

    defmodule PoliteCoordinator do
      @moduledoc false
      # Asks the supervisor instead.
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_info(:quorum_lost, state) do
        Supervisor.terminate_child(
          Argus.Test.Fixtures.Hypothesized.SiblingStop.Sup,
          Argus.Test.Fixtures.Hypothesized.SiblingStop.Workers
        )

        {:noreply, state}
      end
    end
  end

  # ── a sibling's pid cached in init ───────────────────────────────────

  defmodule CachedPid do
    @moduledoc false

    defmodule Sup do
      @moduledoc false
      use Supervisor

      def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_opts) do
        children = [
          Argus.Test.Fixtures.Hypothesized.CachedPid.Store,
          Argus.Test.Fixtures.Hypothesized.CachedPid.Client
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    defmodule RestSup do
      @moduledoc false
      use Supervisor

      def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_opts) do
        children = [
          Argus.Test.Fixtures.Hypothesized.CachedPid.Store,
          Argus.Test.Fixtures.Hypothesized.CachedPid.OrderedClient
        ]

        Supervisor.init(children, strategy: :rest_for_one)
      end
    end

    defmodule Store do
      @moduledoc false
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(state), do: {:ok, state}

      @impl true
      def handle_call(:get, _from, state), do: {:reply, state, state}
    end

    defmodule Client do
      @moduledoc false
      # Keeps the pid it found at boot; a Store restart leaves it dead.
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_) do
        {:ok, %{store: Process.whereis(Argus.Test.Fixtures.Hypothesized.CachedPid.Store)}}
      end

      @impl true
      def handle_call(:fetch, _from, state) do
        {:reply, GenServer.call(state.store, :get), state}
      end
    end

    defmodule OrderedClient do
      @moduledoc false
      # Same shape under :rest_for_one: a Store restart restarts this too.
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_) do
        {:ok, %{store: Process.whereis(Argus.Test.Fixtures.Hypothesized.CachedPid.Store)}}
      end

      @impl true
      def handle_call(:fetch, _from, state) do
        {:reply, GenServer.call(state.store, :get), state}
      end
    end
  end
end
