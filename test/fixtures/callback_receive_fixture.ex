defmodule Argus.Test.Fixtures.CallbackReceive do
  @moduledoc """
  Fixtures for the callback-receive analysis.

  Each module is one shape the analysis has to tell apart. The interesting
  ones are the negatives: a spawned closure (runs in another process) and
  the `cancel_timer` flush idiom (guaranteed to match) both contain a
  blocking `receive` and neither is a bug.
  """

  defmodule BlockingInCallback do
    @moduledoc "The real bug: a receive with no `after` on the server's stack."
    @behaviour GenServer

    def init(arg), do: {:ok, arg}

    def handle_call(:wait, _from, state) do
      # Consumes from the mailbox gen_server is managing, and never returns
      # if :reply does not arrive.
      receive do
        :reply -> {:reply, :ok, state}
      end
    end
  end

  defmodule BoundedInCallback do
    @moduledoc "Same placement, but bounded — cannot hang, still steals messages."
    @behaviour GenServer

    def init(arg), do: {:ok, arg}

    def handle_cast(:poll, state) do
      receive do
        :tick -> :ok
      after
        100 -> :ok
      end

      {:noreply, state}
    end
  end

  defmodule BlockingInHelper do
    @moduledoc "One call from the callback — still the same process."
    @behaviour GenServer

    def init(arg), do: {:ok, arg}
    def handle_info(:go, state), do: {:noreply, wait_for_it(state)}

    def wait_for_it(state) do
      receive do
        :done -> state
      end
    end
  end

  defmodule SpawnedReceive do
    @moduledoc """
    A blocking receive inside a spawned closure. It runs in the CHILD
    process, so the server's mailbox is untouched — the analysis must not
    report it, and would if closure edges counted as same-process control.
    """
    @behaviour GenServer

    def init(arg), do: {:ok, arg}

    def handle_cast(:spawn_worker, state) do
      spawn(fn ->
        receive do
          :work -> :ok
        end
      end)

      {:noreply, state}
    end
  end

  defmodule ReceiveInEach do
    @moduledoc """
    A blocking receive inside a closure handed to Enum.each: the closure
    runs in the callback's own process, and so does the wait.
    """
    use GenServer

    @impl true
    def init(peers), do: {:ok, peers}

    @impl true
    def handle_call(:sync, _from, peers) do
      Enum.each(peers, fn peer ->
        send(peer, {:sync, self()})

        receive do
          {:synced, ^peer} -> :ok
        end
      end)

      {:reply, :ok, peers}
    end
  end

  defmodule TimerFlush do
    @moduledoc """
    The documented flush idiom. `cancel_timer/1` returning false means the
    message was already sent, so the receive is guaranteed to match.
    """
    @behaviour GenServer

    def init(arg), do: {:ok, arg}

    def handle_cast(:cancel, %{ref: ref} = state) do
      if Process.cancel_timer(ref) == false do
        receive do
          :tick -> :ok
        end
      end

      {:noreply, %{state | ref: nil}}
    end
  end

  defmodule TimerFlushArmed do
    @moduledoc "The flush idiom in the module that arms the timer: the receive takes its message."
    @behaviour GenServer

    def init(arg), do: {:ok, %{ref: Process.send_after(self(), :tick, 10), arg: arg}}

    def handle_cast(:cancel, %{ref: ref} = state) do
      if Process.cancel_timer(ref) == false do
        receive do
          :tick -> :ok
        end
      end

      {:noreply, %{state | ref: nil}}
    end
  end

  defmodule TimerFlushAfterZero do
    @moduledoc """
    The flush as the cancel_timer docs also give it: cancel, then take the
    timer's message if it was already delivered, without waiting for it.
    """
    @behaviour GenServer

    def init(arg), do: {:ok, %{ref: Process.send_after(self(), :tick, 10), arg: arg}}

    def handle_cast(:reset, %{ref: ref} = state) do
      Process.cancel_timer(ref)

      receive do
        :tick -> :ok
      after
        0 -> :ok
      end

      {:noreply, %{state | ref: Process.send_after(self(), :tick, 10)}}
    end
  end

  defmodule CancelThenBoundedWait do
    @moduledoc """
    Cancels its :tick timer, then waits (with a bound) for a :reply no
    timer sends: a bounded receive is no flush either unless it takes the
    timer's message.
    """
    @behaviour GenServer

    def init(arg), do: {:ok, %{ref: Process.send_after(self(), :tick, 10), arg: arg}}

    def handle_cast(:stop_and_wait, %{ref: ref} = state) do
      Process.cancel_timer(ref)

      receive do
        :reply -> :ok
      after
        100 -> :ok
      end

      {:noreply, %{state | ref: nil}}
    end
  end

  defmodule CancelThenWait do
    @moduledoc """
    Cancels its :tick timer, then blocks on a :reply no timer sends: the
    cancel does not make this receive a flush.
    """
    @behaviour GenServer

    def init(arg), do: {:ok, %{ref: Process.send_after(self(), :tick, 10), arg: arg}}

    def handle_call(:stop_and_wait, _from, %{ref: ref} = state) do
      Process.cancel_timer(ref)

      receive do
        :reply -> {:reply, :ok, %{state | ref: nil}}
      end
    end
  end

  defmodule StatemBlockingInInit do
    @moduledoc """
    The Redix shape: an Erlang-spelled behaviour (`:gen_statem`, not
    `GenStateMachine`) whose init waits on a bare receive, and whose
    terminate/3 does too. The analysis has to canonicalise the declared
    name, or a third of the servers in a dependency tree are invisible to
    it.
    """
    @behaviour :gen_statem

    def callback_mode, do: :state_functions

    def init(owner) do
      receive do
        {:connected, ^owner} -> {:ok, :connected, owner}
        {:stopped, ^owner, reason} -> {:stop, reason}
      end
    end

    def connected(_type, _content, data), do: {:keep_state, data}

    def terminate(_reason, _state, owner) do
      receive do
        {:closed, ^owner} -> :ok
      end
    end
  end

  defmodule PlainProcess do
    @moduledoc "A blocking receive in a module that is not an OTP behaviour."
    def loop do
      receive do
        msg -> msg
      end
    end
  end
end
