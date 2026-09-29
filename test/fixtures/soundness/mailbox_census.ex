defmodule Argus.Test.Soundness.Census.Mailbox do
  @moduledoc """
  Suppression counterexamples and nearby variants. Asserted by
  test/soundness/mailbox_test.exs.
  """
end

# ── A task nobody collects, in a server with a handle_info/2 ─────────
#
# "Async task never awaited" was excused by any handle_info/2 in the
# module, and `use GenServer` injects one: the rule could never fire for
# an Elixir GenServer.

defmodule Argus.Test.Soundness.Census.Mailbox.TickRefresher do
  @moduledoc """
  The census program: handle_cast(:refresh) starts a linked task and
  never awaits it; handle_info/2 takes only :tick, so the task's
  `{ref, result}` is a FunctionClauseError.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(opts) do
    :timer.send_interval(60_000, :tick)
    {:ok, %{opts: opts, data: nil}}
  end

  @impl true
  def handle_cast(:refresh, state) do
    Task.async(fn -> reload(state.opts) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, %{state | data: reload(state.opts)}}

  defp reload(opts), do: Keyword.get(opts, :source, :none)
end

defmodule Argus.Test.Soundness.Census.Mailbox.DefaultRefresher do
  @moduledoc """
  The same start in a server with no handle_info/2 of its own: the one
  `use GenServer` injects logs and drops the reply with its result.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(opts), do: {:ok, %{opts: opts}}

  @impl true
  def handle_cast(:refresh, state) do
    Task.async(fn -> Keyword.get(state.opts, :source, :none) end)
    {:noreply, state}
  end
end

defmodule Argus.Test.Soundness.Census.Mailbox.CatchAllRefresher do
  @moduledoc "A catch-all handle_info/2 of the program's own: it drops the reply too."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(opts), do: {:ok, %{opts: opts}}

  @impl true
  def handle_cast(:refresh, state) do
    Task.async(fn -> Keyword.get(state.opts, :source, :none) end)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Census.Mailbox.RefConsumer do
  @moduledoc "Quiet: handle_info/2 takes the reply by its reference."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(opts), do: {:ok, %{opts: opts, data: nil}}

  @impl true
  def handle_cast(:refresh, state) do
    Task.async(fn -> Keyword.get(state.opts, :source, :none) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({ref, data}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | data: data}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
end

defmodule Argus.Test.Soundness.Census.Mailbox.TupleConsumer do
  @moduledoc "Quiet: handle_info/2 takes any two-element tuple, the reply among them."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  @impl true
  def init(opts), do: {:ok, %{opts: opts, data: nil}}

  @impl true
  def handle_cast(:refresh, state) do
    Task.async(fn -> Keyword.get(state.opts, :source, :none) end)
    {:noreply, state}
  end

  @impl true
  def handle_info({_ref, data}, state), do: {:noreply, %{state | data: data}}
  def handle_info(_msg, state), do: {:noreply, state}
end

# ── A self-sent tag in a function that also sends elsewhere ──────────
#
# "Server sends itself a tag it cannot handle" excused a function
# wholesale once it called or cast to any other module.

defmodule Argus.Test.Soundness.Census.Mailbox.Audit do
  @moduledoc "Keeps an audit log of casts."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, []}

  @impl true
  def handle_cast({:log, entry}, entries), do: {:noreply, [entry | entries]}
end

defmodule Argus.Test.Soundness.Census.Mailbox.AuditedCounter do
  @moduledoc """
  The census program: bump/1 logs to Audit, then calls its own server
  with {:bump, n}; handle_call/3 was renamed to {:incr, n}, and every bump
  is a FunctionClauseError in the server.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Mailbox.Audit

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def bump(n) do
    GenServer.cast(Audit, {:log, {:bump, n}})
    GenServer.call(__MODULE__, {:bump, n})
  end

  def value, do: GenServer.call(__MODULE__, :value)

  @impl true
  def init(_opts), do: {:ok, 0}

  @impl true
  def handle_call({:incr, n}, _from, count), do: {:reply, count + n, count + n}
  def handle_call(:value, _from, count), do: {:reply, count, count}
end

defmodule Argus.Test.Soundness.Census.Mailbox.AuditedCaster do
  @moduledoc """
  The cast twin: reset/0 logs to Audit, then casts its own server a :clear
  its handle_cast/2 (which takes :reset) has no clause for. The :log cast
  to Audit is Audit's business, not this server's.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Mailbox.Audit

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def reset do
    GenServer.cast(Audit, {:log, :reset})
    GenServer.cast(__MODULE__, :clear)
  end

  @impl true
  def init(_opts), do: {:ok, 0}

  @impl true
  def handle_cast(:reset, _count), do: {:noreply, 0}
end

defmodule Argus.Test.Soundness.Census.Mailbox.SelfCaster do
  @moduledoc """
  A handle_call/3 that logs to Audit and casts self() a tag its
  handle_cast/2 does not take.
  """
  use GenServer

  alias Argus.Test.Soundness.Census.Mailbox.Audit

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, 0}

  @impl true
  def handle_call(:touch, _from, count) do
    GenServer.cast(Audit, {:log, :touch})
    GenServer.cast(self(), :recount)
    {:reply, :ok, count}
  end

  @impl true
  def handle_cast(:reset, _count), do: {:noreply, 0}
end

# ── An init/1 watchdog whose leftover a clause acts on ──────────────
#
# The local-timer rule excused a timer armed and cancelled in init/1:
# init/1 runs once, so no next run takes the leftover. handle_info/2 does.

defmodule Argus.Test.Soundness.Census.Mailbox.HandshakeConn do
  @moduledoc """
  The census program: a watchdog armed and cancelled in init/1, without a
  flush. A :handshake_timeout it delivered while init/1 blocked is taken
  by handle_info/2 after init returns, and stops a server whose handshake
  succeeded.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :handshake_timeout, 5_000)
    sock = handshake(opts)
    Process.cancel_timer(ref)
    {:ok, %{sock: sock}}
  end

  @impl true
  def handle_info(:handshake_timeout, s), do: {:stop, :handshake_timeout, s}
  def handle_info(_msg, s), do: {:noreply, s}

  defp handshake(opts),
    do: :gen_tcp.connect(Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :port), [:binary])
end

defmodule Argus.Test.Soundness.Census.Mailbox.RetryConn do
  @moduledoc """
  A clause that takes the watchdog's message to retry: the leftover
  reconnects a server that is already connected.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :connect_timeout, 5_000)
    sock = :gen_tcp.connect(Keyword.fetch!(opts, :host), 80, [:binary])
    Process.cancel_timer(ref)
    {:ok, %{opts: opts, sock: sock}}
  end

  @impl true
  def handle_info(:connect_timeout, s), do: {:noreply, %{s | sock: reconnect(s.opts)}}

  defp reconnect(opts), do: :gen_tcp.connect(Keyword.fetch!(opts, :host), 80, [:binary])
end

defmodule Argus.Test.Soundness.Census.Mailbox.DroppedWatchdog do
  @moduledoc "Quiet: the leftover reaches only a catch-all, which drops it."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :slow_start, 5_000)
    sock = :gen_tcp.connect(Keyword.fetch!(opts, :host), 80, [:binary])
    Process.cancel_timer(ref)
    {:ok, %{sock: sock}}
  end

  @impl true
  def handle_info(_msg, s), do: {:noreply, s}
end

defmodule Argus.Test.Soundness.Census.Mailbox.FlushedWatchdog do
  @moduledoc "Quiet: init/1 flushes the watchdog's message after the cancel."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    ref = Process.send_after(self(), :open_timeout, 5_000)
    sock = :gen_tcp.connect(Keyword.fetch!(opts, :host), 80, [:binary])
    Process.cancel_timer(ref)

    receive do
      :open_timeout -> :ok
    after
      0 -> :ok
    end

    {:ok, %{sock: sock}}
  end

  @impl true
  def handle_info(:open_timeout, s), do: {:stop, :open_timeout, s}
end
