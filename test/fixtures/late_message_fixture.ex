defmodule Argus.Test.Fixtures.LateMessage do
  @moduledoc """
  Fixtures for `partial_handler`'s "late_message" source: what can leave
  a message in a server's mailbox that its partial handle_info/2 does
  not take, and what cannot.
  """

  defmodule WarmerMacro do
    @moduledoc "A library's `use` that writes the whole handle_info/2, as Cachex.Warmer does."

    defmacro __using__(_opts) do
      quote location: :keep, generated: true do
        use GenServer

        def init(state) do
          Process.send_after(self(), {:warm, nil}, 1_000)
          {:ok, state}
        end

        def handle_info({:warm, _callers}, state) do
          execute(state)
          Process.send_after(self(), {:warm, nil}, 1_000)
          {:noreply, state}
        end
      end
    end
  end

  defmodule Warmer do
    @moduledoc "Its handle_info/2 is the macro's alone; its execute/1 runs a fun from its state."
    use Argus.Test.Fixtures.LateMessage.WarmerMacro

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def execute(state), do: state.loader.()
  end

  defmodule MetricsMacro do
    @moduledoc "Injects one handle_info/2 clause ahead of the module's own, as Sequin.ProcessMetrics does."

    defmacro __using__(_opts) do
      quote do
        def handle_info(:metrics, state), do: {:noreply, state}
      end
    end
  end

  defmodule MixedHandler do
    @moduledoc "The macro's clause first, then the module's own: not the macro's alone."
    use GenServer
    use Argus.Test.Fixtures.LateMessage.MetricsMacro

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    def handle_info(:refresh, state), do: {:noreply, state}
  end

  defmodule HandsClosure do
    @moduledoc "Runs a closure it builds through a helper that calls its parameter."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.send_after(self(), :refresh, 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_info(:refresh, state) do
      value = with_retry(fn -> Map.get(state, :value) end)
      Process.send_after(self(), :refresh, 1_000)
      {:noreply, Map.put(state, :value, value)}
    end

    defp with_retry(fun) do
      fun.()
    rescue
      _ -> nil
    end
  end

  defmodule TimedCall do
    @moduledoc "Gives up on a call after a second: gen drops the reply that comes later."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.send_after(self(), :poll, 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_info(:poll, state) do
      _ = GenServer.call(:elsewhere, :status, 1_000)
      Process.send_after(self(), :poll, 1_000)
      {:noreply, state}
    end
  end

  defmodule StartTimer do
    @moduledoc "Arms :erlang.start_timer for itself and has the :timeout clause."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      ref = :erlang.start_timer(1_000, self(), :idle)
      {:ok, Map.put(opts, :idle, ref)}
    end

    @impl true
    def handle_info({:timeout, ref, :idle}, %{idle: ref} = state) do
      {:noreply, Map.put(state, :idle, :erlang.start_timer(1_000, self(), :idle))}
    end
  end

  defmodule StartTimerIdle do
    @moduledoc """
    Arms :erlang.start_timer for itself — `{:timeout, ref, :refresh}` —
    and has only GenServer's idle `:timeout` atom and one other clause:
    the 3-tuple has no clause.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(state) do
      :erlang.start_timer(1_000, self(), :refresh)
      {:ok, state, 5_000}
    end

    @impl true
    def handle_info(:timeout, state), do: {:stop, :normal, state}
    def handle_info(:other, state), do: {:noreply, state}
  end

  defmodule CallsInClosure do
    @moduledoc """
    Runs a callback read from its state inside a closure Enum.each runs
    in this process: the closure calls through what it captured.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast(:go, state) do
      callback = state.callback
      Enum.each(state.items, fn item -> callback.(item) end)
      {:noreply, state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule HandsMixed do
    @moduledoc """
    Hands a helper an unseen fun (from a persistent term) in one argument
    and a closure it builds in the other; the helper runs both.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast(:go, state) do
      run(:persistent_term.get(:hook), fn -> :done end)
      {:noreply, state}
    end

    defp run(hook, done) do
      hook.()
      done.()
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}
  end

  defmodule LogsOnTick do
    @moduledoc "Logs on each tick: the logger's handlers run by value, out of this mailbox's way."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      Process.send_after(self(), :tick, 1_000)
      {:ok, opts}
    end

    @impl true
    def handle_info(:tick, state) do
      :logger.notice(~c"tick")
      Process.send_after(self(), :tick, 1_000)
      {:noreply, state}
    end
  end

  defmodule RunsSentFun do
    @moduledoc "Runs, through a helper, a fun a cast hands it: code the program does not show."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_cast({:run, fun}, state) do
      run(fun)
      {:noreply, state}
    end

    @impl true
    def handle_info(:tick, state), do: {:noreply, state}

    defp run(fun), do: fun.()
  end
end
