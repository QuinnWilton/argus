defmodule Argus.Test.Fixtures.TimerLoop do
  @moduledoc """
  Periodic timer loops, and the paths that arm one again while it runs.

  A handle_info/2 clause that re-arms its own message is a loop. Another
  callback that arms the same message adds a second loop unless it
  stops the running one first; every such event multiplies the work
  (vernemq's acl and passwd reloaders, realtime#1389, Livebook's
  RuntimeServer).

  The positive modules are loops a second path multiplies; the quiet
  ones are loops that stay one.
  """

  # vernemq's vmq_acl_reloader: the loop drops the ref it arms, and the
  # config change cancels the ref init/1 kept, long since fired, before
  # arming again.
  defmodule ReloadLoop do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def config_changed, do: GenServer.cast(__MODULE__, :config_changed)

    def init(_opts), do: {:ok, init_state(%{timer: nil, interval: 1000})}

    def handle_cast(:config_changed, state), do: {:noreply, init_state(state)}

    def handle_info(:reload, state) do
      reload()
      Process.send_after(self(), :reload, state.interval)
      {:noreply, state}
    end

    def init_state(state) do
      if state.timer, do: Process.cancel_timer(state.timer)
      %{state | timer: Process.send_after(self(), :reload, state.interval)}
    end

    def reload, do: :ok
  end

  # One helper arms for the loop and for a reset, and keeps the ref; the
  # reset stores over it without cancelling.
  defmodule SharedScheduler do
    use GenServer

    def init(_), do: {:ok, schedule(%{timer: nil})}

    def handle_info(:tick, state), do: {:noreply, schedule(state)}
    def handle_cast(:reset, state), do: {:noreply, schedule(state)}

    def schedule(state), do: %{state | timer: Process.send_after(self(), :tick, 1000)}
  end

  # Livebook's RuntimeServer before e9ea88e: the owner change kicks the
  # loop with a message of its own while the loop's timer is pending.
  defmodule SelfKick do
    use GenServer

    def init(_), do: {:ok, %{owner: nil}}

    def handle_cast({:set_owner, owner}, state) do
      send(self(), :report)
      {:noreply, %{state | owner: owner}}
    end

    def handle_info(:report, state) do
      send(state.owner, :usage)
      Process.send_after(self(), :report, 15_000)
      {:noreply, state}
    end
  end

  # A heartbeat that keeps its ref under :beat_ref: the resume clause
  # cancels it before arming again, the reconnect clause does not.
  defmodule KeptRefRearm do
    use GenServer

    def init(_), do: {:ok, %{beat_ref: beat_later()}}

    def handle_info(:beat, state) do
      ping()
      {:noreply, %{state | beat_ref: beat_later()}}
    end

    def handle_info(:reconnected, state) do
      {:noreply, %{state | beat_ref: beat_later()}}
    end

    def handle_info(:resumed, state) do
      cancel(state.beat_ref)
      {:noreply, %{state | beat_ref: beat_later()}}
    end

    def beat_later, do: Process.send_after(self(), :beat, 1000)
    def cancel(nil), do: :ok
    def cancel(ref), do: Process.cancel_timer(ref)
    def ping, do: :ok
  end

  # A cast that runs the loop's clause itself, with the loop's message.
  defmodule DirectKick do
    use GenServer

    def init(_), do: {:ok, %{}}

    def handle_cast(:now, state), do: handle_info(:poll, state)

    def handle_info(:poll, state) do
      Process.send_after(self(), :poll, 5000)
      {:noreply, state}
    end
  end

  # ── Quiet ──────────────────────────────────────────────────────────

  # Armed in init/1 and by the loop itself: one loop.
  defmodule InitOnly do
    use GenServer

    def init(_) do
      Process.send_after(self(), :tick, 1000)
      {:ok, %{}}
    end

    def handle_info(:tick, state) do
      Process.send_after(self(), :tick, 1000)
      {:noreply, state}
    end
  end

  # The reset cancels the ref the loop keeps before arming again.
  defmodule CancelFirst do
    use GenServer

    def init(_), do: {:ok, %{timer: Process.send_after(self(), :tick, 1000)}}

    def handle_info(:tick, state),
      do: {:noreply, %{state | timer: Process.send_after(self(), :tick, 1000)}}

    def handle_cast(:reset, state) do
      Process.cancel_timer(state.timer)
      {:noreply, %{state | timer: Process.send_after(self(), :tick, 1000)}}
    end
  end

  # The loop cancels its own kept timer before re-arming, so a kick that
  # starts another chain folds into it at the next tick.
  defmodule IdempotentLoop do
    use GenServer

    def init(_), do: {:ok, %{timer: nil}}

    def handle_cast(:poke, state) do
      send(self(), :tick)
      {:noreply, state}
    end

    def handle_info(:tick, state) do
      if state.timer, do: Process.cancel_timer(state.timer)
      {:noreply, %{state | timer: Process.send_after(self(), :tick, 1000)}}
    end
  end

  # The message carries a ref the loop compares: a stale one is dropped.
  defmodule RefTagged do
    use GenServer

    def init(_), do: {:ok, arm(%{ref: nil})}

    def handle_cast(:reset, state), do: {:noreply, arm(state)}

    def handle_info({:tick, ref}, %{ref: ref} = state), do: {:noreply, arm(state)}
    def handle_info({:tick, _stale}, state), do: {:noreply, state}

    def arm(state) do
      ref = make_ref()
      Process.send_after(self(), {:tick, ref}, 1000)
      %{state | ref: ref}
    end
  end

  # handle_continue/2 runs once after init/1 here, as it most often does.
  defmodule ContinueArm do
    use GenServer

    def init(_), do: {:ok, %{}, {:continue, :start}}

    def handle_continue(:start, state) do
      Process.send_after(self(), :tick, 1000)
      {:noreply, state}
    end

    def handle_info(:tick, state) do
      Process.send_after(self(), :tick, 1000)
      {:noreply, state}
    end
  end

  # The second arm is for another process's loop.
  defmodule OtherProcess do
    use GenServer

    def init(_), do: {:ok, %{peer: nil}}

    def handle_cast({:kick, peer}, state) do
      Process.send_after(peer, :tick, 1000)
      {:noreply, state}
    end

    def handle_info(:tick, state) do
      Process.send_after(self(), :tick, 1000)
      {:noreply, state}
    end
  end

  # ejabberd_redis: a reconnect that re-arms only when the connect fails,
  # a retry loop that ends once connected; the exit of the connection
  # starts it again, when no retry runs.
  defmodule RetryLoop do
    use GenServer

    def init(_) do
      send(self(), :connect)
      {:ok, %{conn: nil}}
    end

    def handle_info(:connect, %{conn: nil} = state) do
      case connect() do
        {:ok, conn} ->
          {:noreply, %{state | conn: conn}}

        :error ->
          Process.send_after(self(), :connect, 1000)
          {:noreply, state}
      end
    end

    def handle_info({:EXIT, _pid, _reason}, state) do
      send(self(), :connect)
      {:noreply, %{state | conn: nil}}
    end

    def connect, do: Application.get_env(:probe, :redis, :error)
  end

  # A Channel's `send(self(), :after_join)` from join: the clause for it
  # runs once and starts the loop, as init/1 would.
  defmodule AfterJoin do
    use GenServer

    def init(_) do
      send(self(), :after_join)
      {:ok, %{}}
    end

    def handle_info(:after_join, state) do
      Process.send_after(self(), :refresh, 60_000)
      {:noreply, state}
    end

    def handle_info(:refresh, state) do
      Process.send_after(self(), :refresh, 60_000)
      {:noreply, state}
    end
  end

  # vernemq's vmq_swc_store: messages deferred while a write is pending are
  # handed back to handle_info/2 when it is done; the deferred tick is the
  # same tick, and its own clause re-arms it.
  defmodule Redispatch do
    use GenServer

    def init(_), do: {:ok, %{deferred: [], busy: false}}

    def handle_info(:gc, %{busy: true} = state),
      do: {:noreply, %{state | deferred: [:gc | state.deferred]}}

    def handle_info(:gc, state) do
      Process.send_after(self(), :gc, 15_000)
      {:noreply, state}
    end

    def handle_info(:write_done, state), do: drain(%{state | busy: false})

    def drain(%{deferred: []} = state), do: {:noreply, state}

    def drain(%{deferred: [msg | rest]} = state) do
      {:noreply, state} = handle_info(msg, %{state | deferred: rest})
      drain(state)
    end
  end

  # MongooseIM's system metrics: while the last reporter still runs, the
  # tick kills it and hands itself the tick again. The same tick, in the
  # loop's own clause.
  defmodule SameTagResend do
    use GenServer

    def init(_), do: {:ok, %{reporter: nil}}

    def handle_info(:report, %{reporter: nil} = state) do
      Process.send_after(self(), :report, 60_000)
      {:noreply, %{state | reporter: spawn(fn -> :ok end)}}
    end

    def handle_info(:report, state) do
      Process.exit(state.reporter, :kill)
      send(self(), :report)
      {:noreply, %{state | reporter: nil}}
    end
  end

  # init/1 casts the process its own first load, which starts the loop:
  # the cast's clause runs once, as init/1 does.
  defmodule CastFromInit do
    use GenServer

    def init(_) do
      GenServer.cast(self(), :initial_load)
      {:ok, %{}}
    end

    def handle_cast(:initial_load, state) do
      Process.send_after(self(), :refresh, 30_000)
      {:noreply, state}
    end

    def handle_info(:refresh, state) do
      Process.send_after(self(), :refresh, 30_000)
      {:noreply, state}
    end
  end

  # The same first load, also cast by the module's API: every call of
  # reload/1 adds a loop.
  defmodule CastFromInitAndApi do
    use GenServer

    def reload(pid), do: GenServer.cast(pid, :first_load)

    def init(_) do
      GenServer.cast(self(), :first_load)
      {:ok, %{}}
    end

    def handle_cast(:first_load, state) do
      Process.send_after(self(), :refresh, 30_000)
      {:noreply, state}
    end

    def handle_info(:refresh, state) do
      Process.send_after(self(), :refresh, 30_000)
      {:noreply, state}
    end
  end

  # A one-shot retry, not a loop: no clause for :retry arms :retry.
  defmodule OneShot do
    use GenServer

    def init(_), do: {:ok, %{}}

    def handle_cast(:later, state) do
      Process.send_after(self(), :retry, 1000)
      {:noreply, state}
    end

    def handle_info(:retry, state), do: {:noreply, state}
  end
end
