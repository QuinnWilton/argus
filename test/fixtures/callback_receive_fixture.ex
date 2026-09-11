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

  defmodule StatemBlockingInInit do
    @moduledoc """
    The Redix shape: an Erlang-spelled behaviour (`:gen_statem`, not
    `GenStateMachine`) whose init waits on a bare receive. The analysis
    has to canonicalise the declared name, or a third of the servers in a
    dependency tree are invisible to it.
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
