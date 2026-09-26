# Real mailbox timer bugs a suppression once silenced (review 2, items
# 19 and 21), and the adversarial shapes beside each:
# test/soundness/mailbox_test.exs asserts the finding each must keep.

defmodule Argus.Test.Soundness.Mailbox.FlushTwoCallers do
  @moduledoc false
  # A periodic :check timer kept under :tref. The helper cancel_check/1
  # reads the field and cancels it; two callers use it. :pause flushes a
  # tick already delivered; :reset re-arms WITHOUT flushing, so a tick
  # delivered before the cancel is handled as the next one (an extra
  # check, and with it an extra re-arm). The :pause caller's flush is on
  # another path, not the :reset one.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)

  @impl true
  def init(_), do: {:ok, %{tref: nil, n: 0}}

  @impl true
  def handle_cast(:reset, state) do
    state = cancel_check(state)
    {:noreply, %{state | tref: Process.send_after(self(), :check, 1000)}}
  end

  @impl true
  def handle_info(:pause, state) do
    state = cancel_check(state)

    receive do
      :check -> :ok
    after
      0 -> :ok
    end

    {:noreply, state}
  end

  def handle_info(:check, state) do
    {:noreply, %{state | n: state.n + 1, tref: Process.send_after(self(), :check, 1000)}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp cancel_check(state) do
    if state.tref, do: Process.cancel_timer(state.tref)
    %{state | tref: nil}
  end
end

defmodule Argus.Test.Soundness.Mailbox.ContinueLoop do
  @moduledoc false
  # A periodic poll that re-arms :poll on every path and does its work in
  # handle_continue/2 (the modern shape: the tick hands the fetch to a
  # continue). The ref is dropped, and handle_cast(:refresh_now) arms
  # :poll again while the loop's timer is pending: every refresh_now adds
  # a second loop, as vernemq's reloaders do.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  def refresh_now(pid), do: GenServer.cast(pid, :refresh_now)

  @impl true
  def init(_) do
    Process.send_after(self(), :poll, 5000)
    {:ok, %{items: []}}
  end

  @impl true
  def handle_cast(:refresh_now, s) do
    Process.send_after(self(), :poll, 0)
    {:noreply, s}
  end

  @impl true
  def handle_info(:poll, s) do
    Process.send_after(self(), :poll, 5000)
    {:noreply, s, {:continue, :fetch}}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl true
  def handle_continue(:fetch, s), do: {:noreply, %{s | items: fetch()}}

  defp fetch, do: []
end

defmodule Argus.Test.Soundness.Mailbox.NilGuardRunning do
  @moduledoc false
  # A periodic :tick loop keeps its ref under :tref. set_interval/2 arms
  # again only when the loop IS running (the field is not nil) and does
  # not cancel the pending timer: the running loop and the new one both
  # tick from then on, every interval change adds one. The nil test is
  # the opposite of Broadway's "arm only while empty" guard.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  def set_interval(pid, ms), do: GenServer.call(pid, {:set_interval, ms})

  @impl true
  def init(_), do: {:ok, schedule(%{interval: 1000, tref: nil, n: 0}, 1000)}

  @impl true
  def handle_call({:set_interval, ms}, _from, %{tref: tref} = s) do
    s =
      case tref do
        nil -> %{s | interval: ms}
        _running -> schedule(%{s | interval: ms}, ms)
      end

    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:tick, s) do
    %{interval: ms, n: n} = s
    {:noreply, schedule(%{s | n: n + 1}, ms)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp schedule(s, ms), do: %{s | tref: Process.send_after(self(), :tick, ms)}
end

defmodule Argus.Test.Soundness.Mailbox.HelperCancelsElsewhere do
  @moduledoc false
  # A periodic :refresh loop keeps its ref under :tref. update/2 applies
  # a config: disabling cancels the timer (stop_timer/1), but a new
  # interval re-arms WITHOUT cancelling the pending one — every interval
  # change adds a loop. The cancel is in a helper the cast calls, on
  # another branch than the one that re-arms.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o)
  def update(pid, cfg), do: GenServer.cast(pid, {:update, cfg})

  @impl true
  def init(_), do: {:ok, schedule(%{tref: nil, interval: 1000}, 1000)}

  @impl true
  def handle_cast({:update, cfg}, s), do: {:noreply, apply_config(s, cfg)}

  @impl true
  def handle_info(:refresh, s) do
    %{interval: ms} = s
    {:noreply, schedule(s, ms)}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp apply_config(s, %{enabled: false}), do: stop_timer(s)
  defp apply_config(s, %{interval: ms}), do: schedule(%{s | interval: ms}, ms)

  defp stop_timer(%{tref: ref} = s) do
    Process.cancel_timer(ref)
    %{s | tref: nil}
  end

  defp schedule(s, ms), do: %{s | tref: Process.send_after(self(), :refresh, ms)}
end

defmodule Argus.Test.Soundness.Mailbox.HandsDown do
  @moduledoc false
  # The ref handed down to a cancel helper by two callers; only one flushes.
  use GenServer
  @impl true
  def init(_), do: {:ok, %{tref: nil}}
  @impl true
  def handle_cast(:reset, s) do
    stop(s.tref)
    {:noreply, %{s | tref: Process.send_after(self(), :check, 1000)}}
  end

  @impl true
  def handle_info(:pause, s) do
    stop(s.tref)

    receive do
      :check -> :ok
    after
      0 -> :ok
    end

    {:noreply, s}
  end

  def handle_info(:check, s),
    do: {:noreply, %{s | tref: Process.send_after(self(), :check, 1000)}}

  def handle_info(_, s), do: {:noreply, s}
  defp stop(nil), do: :ok
  defp stop(ref), do: Process.cancel_timer(ref)
end

defmodule Argus.Test.Soundness.Mailbox.ContinueHelper do
  @moduledoc false
  # Re-arms, then tail-calls a helper that hands on to handle_continue.
  use GenServer
  @impl true
  def init(_), do: {:ok, %{}}
  @impl true
  def handle_cast(:now, s) do
    Process.send_after(self(), :poll, 0)
    {:noreply, s}
  end

  @impl true
  def handle_info(:poll, s) do
    Process.send_after(self(), :poll, 5000)
    fetch_later(s)
  end

  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def handle_continue(:fetch, s), do: {:noreply, s}
  defp fetch_later(s), do: {:noreply, s, {:continue, :fetch}}
end

defmodule Argus.Test.Soundness.Mailbox.TruthyGuard do
  @moduledoc false
  # Arms again when the ref is set (a truthy test).
  use GenServer
  @impl true
  def init(_), do: {:ok, %{tref: nil}}
  @impl true
  def handle_call(:bump, _f, s) do
    s = if s.tref, do: %{s | tref: Process.send_after(self(), :tick, 10)}, else: s
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:tick, s), do: {:noreply, %{s | tref: Process.send_after(self(), :tick, 1000)}}
  def handle_info(_, s), do: {:noreply, s}
end

defmodule Argus.Test.Soundness.Mailbox.BranchCancel do
  @moduledoc false
  # The arming helper cancels on one branch and arms on the other.
  use GenServer
  @impl true
  def init(_), do: {:ok, %{tref: nil}}
  @impl true
  def handle_cast({:set, cfg}, s), do: {:noreply, configure(s, cfg)}
  @impl true
  def handle_info(:refresh, s),
    do: {:noreply, %{s | tref: Process.send_after(self(), :refresh, 1000)}}

  def handle_info(_, s), do: {:noreply, s}

  defp configure(s, :off) do
    Process.cancel_timer(s.tref)
    %{s | tref: nil}
  end

  defp configure(s, ms), do: %{s | tref: Process.send_after(self(), :refresh, ms)}
end
