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

  # EMQX's BPAPI shape (emqx#18287 fixed about fifteen callers): the rpc
  # is the whole body of a proto module's function, a facade returns the
  # proto's answer, and the API handler matches the facade's result for
  # ok and error only. The {:badrpc, _} a gone node answers passes
  # through both wrappers and meets the handler's case.
  defmodule RpcProto do
    @moduledoc false
    def delete(node, id), do: :rpc.call(node, :ets, :delete, [:delayed, id])

    def alive(node, pid), do: :rpc.call(node, :erlang, :is_process_alive, [pid])

    # Takes the failure itself: no wrapper.
    def lookup(node, id) do
      case :rpc.call(node, :ets, :lookup, [:delayed, id]) do
        {:badrpc, reason} -> {:error, reason}
        rows -> {:ok, rows}
      end
    end
  end

  defmodule RpcFacade do
    @moduledoc false
    def delete(node, id), do: RpcProto.delete(node, id)
  end

  defmodule RpcWrapperCaller do
    @moduledoc false
    def delete(node, id) do
      case RpcFacade.delete(node, id) do
        true -> 204
        {:error, :not_found} -> 404
      end
    end

    # rabbit:await_startup/2's shape: true and false, and no clause for
    # the {:badrpc, _} is_booting/1 passes through.
    def status(node, pid) do
      case RpcProto.alive(node, pid) do
        true -> :up
        false -> :down
      end
    end
  end

  defmodule RpcWrapperCallerHandled do
    @moduledoc false
    def delete(node, id) do
      case RpcFacade.delete(node, id) do
        true -> 204
        {:badrpc, _} -> 503
      end
    end

    def lookup(node, id) do
      case RpcProto.lookup(node, id) do
        {:ok, rows} -> rows
        {:error, _} -> []
      end
    end

    def passes_on(node, id), do: {:result, RpcFacade.delete(node, id)}
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

  defmodule BlockCallCaseNoBadrpc do
    @moduledoc false
    # :rpc.block_call answers a gone node as :rpc.call does.
    def status(node) do
      case :rpc.block_call(node, :mnesia, :system_info, [:running_db_nodes]) do
        nodes when is_list(nodes) -> {:ok, nodes}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule YieldBoolean do
    @moduledoc false
    # :rpc.yield hands back the {:badrpc, _} an async_call got.
    def alive?(pid) do
      key = :rpc.async_call(node(pid), Process, :alive?, [pid])
      Enum.member?(Node.list(), node(pid)) && :rpc.yield(key)
    end
  end

  defmodule NbYieldCase do
    @moduledoc false
    # nb_yield wraps the answer: a case over {:value, _} and :timeout is
    # not the shape the rule reads.
    def poll(key) do
      case :rpc.nb_yield(key, 1000) do
        {:value, nodes} when is_list(nodes) -> {:ok, nodes}
        :timeout -> :pending
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

  defmodule TimerCancelInOwnClause do
    @moduledoc false
    # supavisor's Cluster.Strategy.Postgres: the :heartbeat clause cancels
    # the heartbeat timer — the one whose message it is handling, already
    # fired — and re-arms it. Nothing stale can be left behind.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, heartbeat: arm(interval)}}

    @impl true
    def handle_info(:heartbeat, state) do
      Process.cancel_timer(state.heartbeat)
      {:noreply, %{state | heartbeat: arm(state.interval)}}
    end

    def handle_info(_other, state), do: {:noreply, state}

    defp arm(interval), do: Process.send_after(self(), :heartbeat, interval)
  end

  defmodule TimerCancelOwnClauseAndDown do
    @moduledoc false
    # supavisor's Manager: the :check clause's own cancel is safe, the
    # :DOWN clause's is not — a :check already delivered is handled after
    # the re-arm. The finding is the :DOWN clause's cancel.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, check: arm(interval)}}

    @impl true
    def handle_info({:DOWN, _ref, _, _pid, _}, state) do
      Process.cancel_timer(state.check)
      {:noreply, %{state | check: arm(state.interval)}}
    end

    def handle_info(:check, state) do
      Process.cancel_timer(state.check)
      {:noreply, %{state | check: arm(state.interval)}}
    end

    defp arm(interval), do: Process.send_after(self(), :check, interval)
  end

  defmodule TimerCancelInTerminate do
    @moduledoc false
    # The cancel lives in a helper only terminate/2 calls: the process is
    # stopping, and no later message will be handled.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    @impl true
    def terminate(_reason, state), do: stop_timer(state)

    defp stop_timer(state), do: Process.cancel_timer(state.timer)

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

  defmodule TimerFlushedElsewhere do
    @moduledoc false
    # A receive for :heartbeat in another function is no flush: the
    # handle_call that cancels and re-arms leaves a delivered :heartbeat
    # behind all the same.
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
    def handle_cast(:stop_beating, state) do
      await_last_beat()
      {:noreply, state}
    end

    @impl true
    def handle_info(:heartbeat, state),
      do: {:noreply, %{state | timer: arm(state.interval)}}

    defp await_last_beat do
      receive do
        :heartbeat -> :ok
      after
        100 -> :ok
      end
    end

    defp arm(interval), do: Process.send_after(self(), :heartbeat, interval)
  end

  defmodule TimerFlushInHelper do
    @moduledoc false
    # The flush lives in a helper the cancelling function calls.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      Process.cancel_timer(state.timer)
      flush_tick()
      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    defp flush_tick do
      receive do
        :tick -> :ok
      after
        0 -> :ok
      end
    end

    defp arm(interval), do: Process.send_after(self(), :tick, interval)
  end

  defmodule TimerCancelHelperFlushInCaller do
    @moduledoc false
    # The ref is handed down to a cancel helper; the caller flushes.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      cancel(state.timer)

      receive do
        :tick -> :ok
      after
        0 -> :ok
      end

      {:reply, :ok, %{state | interval: interval, timer: arm(interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    defp cancel(ref), do: Process.cancel_timer(ref)

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

  defmodule WriteBuffer do
    @moduledoc false
    # Plausible's Ingestion.WriteBuffer: the :tick timer is cancelled and
    # re-armed on handle_cast's buffer-full branch, which every insert
    # can take, and in handle_call(:flush), which only the test helpers
    # request (WriteBufferTestSupport).
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])
    def insert(server, row), do: GenServer.cast(server, {:insert, row})
    def flush(server), do: GenServer.call(server, :flush, :infinity)

    @impl true
    def init(opts) do
      timer = Process.send_after(self(), :tick, opts[:interval])
      {:ok, %{buffer: [], size: 0, max: opts[:max], interval: opts[:interval], timer: timer}}
    end

    @impl true
    def handle_cast({:insert, row}, state) do
      state = %{state | buffer: [row | state.buffer], size: state.size + 1}

      if state.size >= state.max do
        Process.cancel_timer(state.timer)
        timer = Process.send_after(self(), :tick, state.interval)
        {:noreply, %{state | buffer: [], size: 0, timer: timer}}
      else
        {:noreply, state}
      end
    end

    @impl true
    def handle_info(:tick, state) do
      timer = Process.send_after(self(), :tick, state.interval)
      {:noreply, %{state | buffer: [], size: 0, timer: timer}}
    end

    @impl true
    def handle_call(:flush, _from, state) do
      Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), :tick, state.interval)
      {:reply, :ok, %{state | buffer: [], size: 0, timer: timer}}
    end
  end

  defmodule WriteBufferIngest do
    @moduledoc false
    # The program's own caller: every event goes through insert/2.
    def track(event), do: WriteBuffer.insert(WriteBuffer, event)
  end

  defmodule WriteBufferTestSupport do
    @moduledoc false
    # Test support compiled with the program, as Plausible's TestUtils
    # is: it calls into ExUnit, and it is flush/1's only caller.
    def drain do
      ExUnit.Callbacks.on_exit(fn -> :ok end)
      WriteBuffer.flush(WriteBuffer)
    end
  end

  defmodule FlushOnlyBuffer do
    @moduledoc false
    # The same timer cancelled only in handle_call(:flush), which only
    # the test helpers request: still the module's finding, anchored
    # there.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def flush(server), do: GenServer.call(server, :flush_only, :infinity)

    @impl true
    def init(interval), do: {:ok, %{interval: interval, timer: arm(interval)}}

    @impl true
    def handle_call(:flush_only, _from, state) do
      Process.cancel_timer(state.timer)
      {:reply, :ok, %{state | timer: arm(state.interval)}}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, %{state | timer: arm(state.interval)}}

    defp arm(interval), do: Process.send_after(self(), :tick, interval)
  end

  defmodule FlushOnlyBufferTestSupport do
    @moduledoc false
    def drain(server) do
      ExUnit.Callbacks.on_exit(fn -> :ok end)
      FlushOnlyBuffer.flush(server)
    end
  end

  defmodule TwoTimersViaHelper do
    @moduledoc false
    # nebulex's Local.Generation: a cleanup timer and a heartbeat timer,
    # both armed through one helper whose message is a default argument.
    # Each key carries its own message; neither is flushed.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(interval) do
      {:ok,
       %{
         interval: interval,
         cleanup_ref: start_timer(interval * 10, nil, :cleanup),
         heartbeat_ref: start_timer(interval)
       }}
    end

    @impl true
    def handle_call({:set_interval, interval}, _from, state) do
      {:reply, :ok,
       %{
         state
         | interval: interval,
           cleanup_ref: start_timer(interval * 10, state.cleanup_ref, :cleanup),
           heartbeat_ref: start_timer(interval, state.heartbeat_ref)
       }}
    end

    @impl true
    def handle_info(:heartbeat, state),
      do: {:noreply, %{state | heartbeat_ref: start_timer(state.interval, nil)}}

    def handle_info(:cleanup, state), do: {:noreply, state}

    defp start_timer(time, ref \\ nil, event \\ :heartbeat) do
      _ = if ref, do: Process.cancel_timer(ref)
      Process.send_after(self(), event, time)
    end
  end

  defmodule TimerLocalNoFlush do
    @moduledoc false
    # A deadline armed and cancelled within one call, its ref only ever a
    # local: if it fired first, :deadline waits in the mailbox and stops
    # the server on some later call.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:work, job}, _from, state) do
      ref = Process.send_after(self(), :deadline, 5_000)
      result = job.()
      Process.cancel_timer(ref)
      {:reply, result, state}
    end

    @impl true
    def handle_info(:deadline, state), do: {:stop, :deadline, state}
  end

  defmodule TimerLocalFlushed do
    @moduledoc false
    # The same, flushed after the cancel.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:work, job}, _from, state) do
      ref = Process.send_after(self(), :flushed_deadline, 5_000)
      result = job.()
      Process.cancel_timer(ref)

      receive do
        :flushed_deadline -> :ok
      after
        0 -> :ok
      end

      {:reply, result, state}
    end
  end

  defmodule TimerLocalStartTimer do
    @moduledoc false
    # :erlang.start_timer's {:timeout, ref, msg} names the timer.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:work, job}, _from, state) do
      ref = :erlang.start_timer(5_000, self(), :deadline)
      result = job.()
      :erlang.cancel_timer(ref)
      {:reply, result, state}
    end
  end

  defmodule TimerLocalEitherArm do
    @moduledoc false
    # The ref is one of two timers: which one is cancelled is not known.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:work, job, fast?}, _from, state) do
      ref =
        if fast?,
          do: Process.send_after(self(), :fast_deadline, 100),
          else: Process.send_after(self(), :slow_deadline, 5_000)

      result = job.()
      Process.cancel_timer(ref)
      {:reply, result, state}
    end
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

    defmodule RelaySup do
      @moduledoc false
      use Supervisor

      def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_opts) do
        children = [
          Argus.Test.Fixtures.Hypothesized.CachedPid.Store,
          Argus.Test.Fixtures.Hypothesized.CachedPid.Relay
        ]

        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    defmodule Relay do
      @moduledoc false
      # Looks the Store up at boot, but its handler calls the pid each
      # caller hands it, never the one it keeps.
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

      @impl true
      def init(_) do
        {:ok, %{store: Process.whereis(Argus.Test.Fixtures.Hypothesized.CachedPid.Store)}}
      end

      @impl true
      def handle_call({:relay, pid}, _from, state) do
        {:reply, GenServer.call(pid, :get), state}
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
