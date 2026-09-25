defmodule Argus.Test.Fixtures.UnhandledInfo do
  @moduledoc """
  Fixtures for `mailbox.unhandled_info`: a message a GenServer is sent —
  by a send points-to follows to it, a timer it arms for itself, or a
  monitor it takes — that no clause of its handle_info/2 takes. The
  positives are the shapes of real fixes (sequin's :max_memory_check,
  astarte's re-armed :init, oban's leaked listeners, teslamate's
  :repair); the quiet neighbours take the message, hand it on, or cannot
  be judged.
  """

  defmodule MemoryCheck do
    @moduledoc "Arms :memory_check from handle_continue and has clauses for two other messages: a crash."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts, {:continue, :init}}

    @impl true
    def handle_continue(:init, state) do
      schedule_memory_check()
      {:noreply, state}
    end

    @impl true
    def handle_info(:log, state), do: {:noreply, state}
    def handle_info(:changed, state), do: {:noreply, state}

    defp schedule_memory_check, do: Process.send_after(self(), :memory_check, 300_000)
  end

  defmodule Reconnect do
    @moduledoc "Re-arms :connect after a lost connection; only :DOWN has a clause."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts), do: {:ok, :not_connected}

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _reason}, _state) do
      schedule_connect()
      {:noreply, :not_connected}
    end

    defp schedule_connect, do: Process.send_after(self(), :connect, 10_000)
  end

  defmodule Listeners do
    @moduledoc "Monitors each listener and drops the :DOWN in a catch-all: dead listeners pile up."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    def listen, do: GenServer.call(__MODULE__, :listen)

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call(:listen, {pid, _}, listeners) do
      Process.monitor(pid)
      {:reply, :ok, Map.put(listeners, pid, true)}
    end

    @impl true
    def handle_info({:notify, payload}, listeners) do
      for {pid, _} <- listeners, do: send(pid, payload)
      {:noreply, listeners}
    end

    def handle_info(_message, listeners), do: {:noreply, listeners}
  end

  defmodule Repair do
    @moduledoc "Arms :repair on an interval and handles it in handle_cast; handle_info only logs."
    use GenServer
    require Logger

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      {:ok, _} = :timer.send_interval(60_000, self(), :repair)
      {:ok, opts}
    end

    @impl true
    def handle_cast(:repair, state), do: {:noreply, state}

    @impl true
    def handle_info(msg, state) do
      Logger.warning("Unexpected message: #{inspect(msg)}")
      {:noreply, state}
    end
  end

  defmodule Ticker do
    @moduledoc "Sends itself :tick and has no handle_info of its own."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      send(self(), :tick)
      {:ok, opts}
    end
  end

  defmodule Pinger do
    @moduledoc "A client pings the server it started; the server takes only :pong."
    alias Argus.Test.Fixtures.UnhandledInfo.PingServer

    def run do
      {:ok, pid} = PingServer.start_link([])
      send(pid, :ping)
    end
  end

  defmodule PingServer do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info(:pong, state), do: {:noreply, state}
  end

  defmodule EnvelopeCaster do
    @moduledoc """
    Sends the gen behaviours' own envelopes by hand, as rabbit's
    gen_server2:cast/2 does: the server's loop takes a `{:"$gen_cast", _}`
    to handle_cast/2 and a `{:"$gen_call", _, _}` to handle_call/3, never
    to handle_info/2. The `{:refresh_now, _}` beside them is a message.
    """
    alias Argus.Test.Fixtures.UnhandledInfo.EnvelopeServer

    def run do
      {:ok, pid} = EnvelopeServer.start_link([])
      send(pid, {:"$gen_cast", :refresh})
      send(pid, {:"$gen_call", {self(), make_ref()}, :count})
      send(pid, {:refresh_now, 1})
    end
  end

  defmodule EnvelopeServer do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast(:refresh, state), do: {:noreply, state}

    @impl true
    def handle_call(:count, _from, state), do: {:reply, 0, state}

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule Retry do
    @moduledoc "Arms a literal `{:retry, 3}` and re-arms a built `{:backoff, n}`; no clause takes either."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Process.send_after(self(), {:retry, 3}, 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_info(:reset, state) do
      Process.send_after(self(), {:backoff, state}, 1_000)
      {:noreply, state}
    end
  end

  # ── Quiet ─────────────────────────────────────────────────────────

  defmodule WarmUp do
    @moduledoc """
    nerves_hub's CLISessionCache: init arms a literal `{:warm_up, 5}`,
    the clause for it re-arms a built `{:warm_up, n - 1}`, and the heads
    dispatch on tuple arity first (a 4-tuple, a 2-tuple, an atom).
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      Process.send_after(self(), {:warm_up, 5}, 250)
      Process.send_after(self(), :expire, 60_000)
      {:ok, %{}}
    end

    @impl true
    def handle_info({:put, origin, _key, _value}, state) when origin == node(),
      do: {:noreply, state}

    def handle_info({:put, _origin, key, value}, state),
      do: {:noreply, Map.put(state, key, value)}

    def handle_info(:expire, state) do
      Process.send_after(self(), :expire, 60_000)
      {:noreply, state}
    end

    def handle_info({:warm_up, attempts}, state) do
      if attempts > 1, do: Process.send_after(self(), {:warm_up, attempts - 1}, 250)
      {:noreply, state}
    end
  end

  defmodule TerminateWaits do
    @moduledoc """
    Broadway's Terminator: a catch-all drops every message, and
    terminate/2 monitors each process in a `for` and waits for its
    :DOWN there — in the anonymous function the comprehension compiles
    into.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(names), do: {:ok, names}

    @impl true
    def handle_info(_, state), do: {:noreply, state}

    @impl true
    def terminate(_, names) do
      for name <- names, pid = GenServer.whereis(name) do
        ref = Process.monitor(pid)

        receive do
          {:done, ^pid} -> :ok
          {:DOWN, ^ref, _, _, _} -> :ok
        end
      end

      :ok
    end
  end

  defmodule TaskReceives do
    @moduledoc """
    The server arms :tick for itself and has no clause for it; a Task a
    callback starts receives :tick. The Task's receive is the Task's
    mailbox, not the server's: the timer still crashes the server.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state) do
      Process.send_after(self(), :tick, 1_000)
      {:ok, state}
    end

    @impl true
    def handle_cast(:go, state) do
      Task.start(fn ->
        receive do
          :tick -> :ok
        end
      end)

      {:noreply, state}
    end

    @impl true
    def handle_info(:other, state), do: {:noreply, state}
  end

  defmodule Unjudged do
    @moduledoc "A timer whose message is a binary, not an atom or a tagged tuple: not judged."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Process.send_after(self(), "refresh", 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_info("refresh", state), do: {:noreply, state}
  end

  defmodule Handled do
    @moduledoc "Arms :refresh and has a clause for it; monitors and takes :DOWN."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Process.send_after(self(), :refresh, 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_call({:watch, pid}, _from, state) do
      Process.monitor(pid)
      {:reply, :ok, state}
    end

    @impl true
    def handle_info(:refresh, state), do: {:noreply, state}
    def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}
  end

  defmodule Delegates do
    @moduledoc "The catch-all hands every message to a helper, which may take it."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Process.send_after(self(), :flush, 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_info(msg, state), do: handle_message(msg, state)

    defp handle_message(:flush, state), do: {:noreply, state}
    defp handle_message(_other, state), do: {:noreply, state}
  end

  defmodule OpenClause do
    @moduledoc "A clause takes any atom by its type alone; a {ref, result} clause any 2-tuple."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      Process.send_after(self(), :sweep, 1_000)
      send(self(), {:job, 1})
      {:ok, opts}
    end

    @impl true
    def handle_info(event, state) when is_atom(event), do: {:noreply, [event | state]}
    def handle_info({ref, result}, state) when is_reference(ref), do: {:noreply, [result | state]}
  end

  defmodule WaitsForDown do
    @moduledoc "Monitors and waits for the :DOWN in the same callback."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:stop, pid}, _from, state) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end

      {:reply, :ok, state}
    end

    @impl true
    def handle_info(:other, state), do: {:noreply, state}
  end

  defmodule Flushes do
    @moduledoc "Monitors around a call and demonitors with :flush."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:ask, pid}, _from, state) do
      ref = Process.monitor(pid)
      reply = GenServer.call(pid, :question)
      Process.demonitor(ref, [:flush])
      {:reply, reply, state}
    end

    @impl true
    def handle_info(:other, state), do: {:noreply, state}
  end

  defmodule Client do
    @moduledoc "A client function monitors in its caller's process: the :DOWN is the caller's."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def await_down do
      ref = Process.monitor(Process.whereis(__MODULE__))
      ref
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info(:other, state), do: {:noreply, state}
  end

  # ── gen_statem ──────────────────────────────────────────────────────

  defmodule Poller do
    @moduledoc "A state machine arms :poll for itself; no state has a clause for it, :idle no catch-all."
    @behaviour :gen_statem

    def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(opts) do
      Process.send_after(self(), :poll, 1_000)
      {:ok, :idle, opts}
    end

    def idle({:call, from}, :status, data), do: {:keep_state, data, [{:reply, from, :idle}]}
    def idle(:cast, :go, data), do: {:next_state, :busy, data}

    def busy(:info, _msg, data), do: {:keep_state, data}
    def busy(:cast, :stop, data), do: {:next_state, :idle, data}
  end

  defmodule PollerTakes do
    @moduledoc "The same machine with a state that takes :poll: the message is one some state expects."
    @behaviour :gen_statem

    def start_link(opts), do: :gen_statem.start_link(__MODULE__, opts, [])

    @impl true
    def callback_mode, do: :state_functions

    @impl true
    def init(opts) do
      Process.send_after(self(), :poll, 1_000)
      {:ok, :idle, opts}
    end

    def idle(:cast, :go, data), do: {:next_state, :busy, data}

    def busy(:info, :poll, data), do: {:keep_state, data}
    def busy(:cast, :stop, data), do: {:next_state, :idle, data}
  end
end
