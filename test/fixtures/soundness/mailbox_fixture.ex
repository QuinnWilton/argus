defmodule Argus.Test.Soundness.Mailbox do
  @moduledoc """
  Real mailbox bugs a suppression once silenced, and the adversarial
  shapes beside each: `test/soundness/mailbox_test.exs` asserts the
  finding each must keep.
  """

  # ── A :DOWN wait is the clause that takes it, not the receive ────────
  # (review 2, item 5: fe291340 stopped at the loop_rec of any receive
  # with a :DOWN clause, even on the path of its other clause.)

  defmodule ReplyOrDown do
    @moduledoc """
    Monitor a peer, ask it, and wait for its answer or its :DOWN. The ref
    is thrown away, so the answer path cannot demonitor: every answered
    question leaves a live monitor whose :DOWN arrives later.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:ask, pid, q}, _from, state) do
      Process.monitor(pid)
      send(pid, {:question, self(), q})

      receive do
        {:answer, ^pid, a} -> {:reply, {:ok, a}, state}
        {:DOWN, _, :process, ^pid, reason} -> {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _}, state), do: {:noreply, state}
  end

  defmodule ReplyOrDownCaller do
    @moduledoc """
    The same reply-or-:DOWN wait, with the monitor taken in a helper whose
    ref is dropped: the caller's answer path leaves the monitor live.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:ask, pid, q}, _from, state) do
      ask(pid, q)

      receive do
        {:answer, ^pid, a} -> {:reply, {:ok, a}, state}
        {:DOWN, _, :process, ^pid, reason} -> {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _}, state), do: {:noreply, state}

    defp ask(pid, q) do
      Process.monitor(pid)
      send(pid, {:question, self(), q})
      :ok
    end
  end

  defmodule HelperReplyOrDown do
    @moduledoc """
    The reply-or-:DOWN wait in a helper the caller runs after monitoring:
    a call to a function that waits so on one path only is no wait.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:ask, pid, q}, _from, state) do
      Process.monitor(pid)
      send(pid, {:question, self(), q})
      {:reply, await_answer(pid), state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _}, state), do: {:noreply, state}

    defp await_answer(pid) do
      receive do
        {:answer, ^pid, a} -> {:ok, a}
        {:DOWN, _, :process, ^pid, reason} -> {:error, reason}
      end
    end
  end

  defmodule TimedGivesUp do
    @moduledoc """
    The :DOWN taken in a timed receive whose `after` returns: the timeout
    path leaves the monitor live, with its ref gone.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:stop, pid}, _from, state) do
      Process.monitor(pid)
      GenServer.cast(pid, :stop)

      receive do
        {:DOWN, _, :process, ^pid, _} -> {:reply, :ok, state}
      after
        100 -> {:reply, :timeout, state}
      end
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _}, state), do: {:noreply, state}
  end

  defmodule MaybeWaits do
    @moduledoc """
    A helper that waits for the :DOWN on one branch and does not loop:
    the other branch returns with the monitor live.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:stop, pid, wait?}, _from, state) do
      Process.monitor(pid)
      GenServer.cast(pid, :stop)
      {:reply, maybe_wait(pid, wait?), state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _}, state), do: {:noreply, state}

    defp maybe_wait(pid, true) do
      receive do
        {:DOWN, _, :process, ^pid, _} -> :ok
      end
    end

    defp maybe_wait(_pid, false), do: :ok
  end

  defmodule SameBody do
    @moduledoc """
    Two clauses with one body, which the compiler may share: the answer
    clause's path took no :DOWN.
    """
    use GenServer

    @impl true
    def init(_), do: {:ok, %{}}

    @impl true
    def handle_call({:ask, pid}, _from, state) do
      Process.monitor(pid)
      send(pid, {:question, self()})

      receive do
        {:DOWN, _, :process, ^pid, _} -> :ok
        {:answer, ^pid} -> :ok
      end

      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:DOWN, _ref, :process, _pid, _}, state), do: {:noreply, state}
  end
end
