# Shapes the mailbox analysis keeps quiet, or keeps reported, through an
# exclusion no evaluation program exercises (census 2026-09-26); see
# `test/exclusions/mailbox_test.exs` and docs/design/exclusions.md. The
# last two shapes are real bugs an exclusion used to hide.

# terminate/2 bounds a drain with a local timer, then cancels it. The
# process is going away: a :drain_deadline the timer delivered before
# the cancel is never handled by anyone.
defmodule Excl.Mailbox.TerminateDeadline.Pool do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{conns: []}}
  end

  @impl true
  def handle_info(:drain_deadline, s), do: {:noreply, s}
  def handle_info(_msg, s), do: {:noreply, s}

  @impl true
  def terminate(_reason, s) do
    ref = Process.send_after(self(), :drain_deadline, 5_000)
    Enum.each(s.conns, &:gen_tcp.close/1)
    Process.cancel_timer(ref)
    :ok
  end
end

# The same deadline around a drain a call handler runs: the server goes
# on, and a :drain_deadline delivered before the cancel is taken by
# handle_info/2 later, as if a drain had timed out. What terminate/2
# above cannot suffer.
defmodule Excl.Mailbox.CallDeadline.Pool do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:ok, %{conns: [], timed_out: 0}}

  @impl true
  def handle_call(:drain, _from, s) do
    ref = Process.send_after(self(), :drain_deadline, 5_000)
    Enum.each(s.conns, &:gen_tcp.close/1)
    Process.cancel_timer(ref)
    {:reply, :ok, %{s | conns: []}}
  end

  @impl true
  def handle_info(:drain_deadline, s), do: {:noreply, %{s | timed_out: s.timed_out + 1}}
  def handle_info(_msg, s), do: {:noreply, s}
end

# The heartbeat's :beat timer is kept under :timer. pause/0 (the
# product's) cancels it without a flush; the only re-arm is resume/0's,
# and only the test helpers call resume/0. Every arm under the key is
# under test, which is no reason to drop the finding: the product's
# cancel leaves a stale :beat behind all the same, and the finding keeps
# the arm it has.
defmodule Excl.Mailbox.ArmsUnderTest.Heartbeat do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def pause, do: GenServer.cast(__MODULE__, :pause)
  def resume, do: GenServer.call(__MODULE__, :resume)

  @impl true
  def init(_opts), do: {:ok, %{timer: Process.send_after(self(), :beat, 1_000), beats: 0}}

  @impl true
  def handle_cast(:pause, s) do
    Process.cancel_timer(s.timer)
    {:noreply, %{s | timer: nil}}
  end

  @impl true
  def handle_call(:resume, _from, s) do
    {:reply, :ok, %{s | timer: Process.send_after(self(), :beat, 1_000)}}
  end

  @impl true
  def handle_info(:beat, s), do: {:noreply, %{s | beats: s.beats + 1}}
  def handle_info(_msg, s), do: {:noreply, s}
end

defmodule Excl.Mailbox.ArmsUnderTest.Pauser do
  @moduledoc false
  def maintenance_window(fun) do
    Excl.Mailbox.ArmsUnderTest.Heartbeat.pause()
    fun.()
  end
end

defmodule Excl.Mailbox.ArmsUnderTest.HeartbeatTestSupport do
  @moduledoc false
  # Test support compiled with the program: it calls into ExUnit, and it
  # is resume/0's only caller.
  def restart_heartbeat do
    ExUnit.Callbacks.on_exit(fn -> :ok end)
    Excl.Mailbox.ArmsUnderTest.Heartbeat.resume()
  end
end

# Each element's Task.async is started and yielded inside the Enum.map
# fn. The task is linked, so a crashing fetch kills the caller before
# Task.yield can report {:exit, _}: one defect, owned by the named
# function fetch_all/1. The closure it happens in is not a second owner.
defmodule Excl.Mailbox.YieldInClosure.Fanout do
  @moduledoc false
  def fetch_all(urls) do
    Enum.map(urls, fn url ->
      task = Task.async(fn -> fetch(url) end)

      case Task.yield(task, 5_000) || Task.shutdown(task) do
        {:ok, body} -> {:ok, body}
        {:exit, reason} -> {:error, reason}
        nil -> {:error, :timeout}
      end
    end)
  end

  defp fetch(url), do: :httpc.request(String.to_charlist(url))
end

# A library function starts and awaits a linked task inside an Enum.map
# fn: its callers are linked to each task. One defect, owned by
# resize_all/1; the closure it happens in is not a second owner.
defmodule Excl.Mailbox.AwaitInClosure.Thumbs do
  @moduledoc false
  def resize_all(paths) do
    Enum.map(paths, fn path ->
      Task.async(fn -> resize(path) end) |> Task.await(10_000)
    end)
  end

  defp resize(path), do: File.read!(path)
end

# init/1 sends itself :after_init once; that clause starts the :refresh
# loop by running the loop's clause directly (handle_info(:refresh, s)).
# A clause that runs once arms the loop the ticks then carry: there is
# one loop, not two.
defmodule Excl.Mailbox.OnceClauseStartsLoop.Cache do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    send(self(), :after_init)
    {:ok, %{source: Keyword.fetch!(opts, :source), data: %{}}}
  end

  @impl true
  def handle_info(:after_init, s), do: handle_info(:refresh, s)

  def handle_info(:refresh, s) do
    data = load(s.source)
    Process.send_after(self(), :refresh, 60_000)
    {:noreply, %{s | data: data}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp load(source), do: :persistent_term.get(source, %{})
end

# The :tick loop keeps its ref under :timer. handle_call(:pause) cancels
# it; handle_call(%Configure{}) re-arms :tick into :timer without
# cancelling: each reconfigure starts a second loop. The cancel's clause
# has a tag and the arm's (a struct head) has none; they are not one
# clause, and the :pause cancel does not stop the loop %Configure{}
# arms. A real bug the analysis must keep reporting.
defmodule Excl.Mailbox.TaggedCancelUntaggedArm.Configure do
  @moduledoc false
  defstruct interval: 1_000
end

defmodule Excl.Mailbox.TaggedCancelUntaggedArm.Ticker do
  @moduledoc false
  use GenServer
  alias Excl.Mailbox.TaggedCancelUntaggedArm.Configure

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def pause, do: GenServer.call(__MODULE__, :pause)
  def configure(interval), do: GenServer.call(__MODULE__, %Configure{interval: interval})

  @impl true
  def init(_opts),
    do: {:ok, %{timer: Process.send_after(self(), :tick, 1_000), interval: 1_000, n: 0}}

  @impl true
  def handle_call(:pause, _from, s) do
    Process.cancel_timer(s.timer)
    {:reply, :ok, %{s | timer: nil}}
  end

  def handle_call(%Configure{interval: i}, _from, s) do
    {:reply, :ok, %{s | interval: i, timer: Process.send_after(self(), :tick, i)}}
  end

  @impl true
  def handle_info(:tick, s) do
    {:noreply, %{s | n: s.n + 1, timer: Process.send_after(self(), :tick, s.interval)}}
  end

  def handle_info(_msg, s), do: {:noreply, s}
end

# The mirror: handle_call(%Stop{}) (a struct head, no tag) cancels
# :timer; handle_call({:set_interval, i}) (tagged) re-arms :tick into
# :timer without cancelling: each call starts a second loop. The %Stop{}
# cancel does not stop the loop :set_interval arms. A real bug the
# analysis must keep reporting.
defmodule Excl.Mailbox.UntaggedCancelTaggedArm.Stop do
  @moduledoc false
  defstruct []
end

defmodule Excl.Mailbox.UntaggedCancelTaggedArm.Ticker do
  @moduledoc false
  use GenServer
  alias Excl.Mailbox.UntaggedCancelTaggedArm.Stop

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def stop_ticking, do: GenServer.call(__MODULE__, %Stop{})
  def set_interval(i), do: GenServer.call(__MODULE__, {:set_interval, i})

  @impl true
  def init(_opts),
    do: {:ok, %{timer: Process.send_after(self(), :tick, 1_000), interval: 1_000, n: 0}}

  @impl true
  def handle_call(%Stop{}, _from, s) do
    Process.cancel_timer(s.timer)
    {:reply, :ok, %{s | timer: nil}}
  end

  def handle_call({:set_interval, i}, _from, s) do
    {:reply, :ok, %{s | interval: i, timer: Process.send_after(self(), :tick, i)}}
  end

  @impl true
  def handle_info(:tick, s) do
    {:noreply, %{s | n: s.n + 1, timer: Process.send_after(self(), :tick, s.interval)}}
  end

  def handle_info(_msg, s), do: {:noreply, s}
end

# The :reload loop re-arms through schedule/0 and drops the ref;
# handle_cast(:start) arms through the same helper and keeps the ref
# under :timer. Every :start adds a loop no cancel can stop: the
# dropped-ref finding reports it, and a finding under the :timer key
# would repeat it.
defmodule Excl.Mailbox.LoopDropsAndKeeps.Reloader do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def start, do: GenServer.cast(__MODULE__, :start)

  @impl true
  def init(opts), do: {:ok, %{path: Keyword.fetch!(opts, :path), timer: nil, acl: nil}}

  @impl true
  def handle_cast(:start, s), do: {:noreply, %{s | timer: schedule()}}

  @impl true
  def handle_info(:reload, s) do
    acl = File.read!(s.path)
    schedule()
    {:noreply, %{s | acl: acl}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp schedule, do: Process.send_after(self(), :reload, 5_000)
end

# The :poll loop keeps its ref under :timer while it runs.
# handle_cast(:demand) arms :poll only when :timer is nil (a Broadway
# producer's receive_timer: nil), which is when no loop runs: no second
# loop.
defmodule Excl.Mailbox.ArmsWhenEmpty.Producer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def demand, do: GenServer.cast(__MODULE__, :demand)

  @impl true
  def init(_opts), do: {:ok, %{timer: nil, buffer: []}}

  @impl true
  def handle_cast(:demand, %{timer: nil} = s) do
    {:noreply, %{s | timer: Process.send_after(self(), :poll, 0)}}
  end

  def handle_cast(:demand, s), do: {:noreply, s}

  @impl true
  def handle_info(:poll, s) do
    buffer = s.buffer ++ fetch()
    {:noreply, %{s | buffer: buffer, timer: Process.send_after(self(), :poll, 1_000)}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp fetch, do: :persistent_term.get(:excl_mailbox_queue, [])
end

# The same producer arming :poll on every demand, running loop or not:
# each demand while the loop runs starts a second one. What the guard
# above prevents.
defmodule Excl.Mailbox.ArmsAlways.Producer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def demand, do: GenServer.cast(__MODULE__, :demand)

  @impl true
  def init(_opts), do: {:ok, %{timer: nil, buffer: []}}

  @impl true
  def handle_cast(:demand, s) do
    {:noreply, %{s | timer: Process.send_after(self(), :poll, 0)}}
  end

  @impl true
  def handle_info(:poll, s) do
    buffer = s.buffer ++ fetch()
    {:noreply, %{s | buffer: buffer, timer: Process.send_after(self(), :poll, 1_000)}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp fetch, do: :persistent_term.get(:excl_mailbox_queue, [])
end

# A write buffer (Plausible's WriteBuffer shape) whose flush/0 only test
# support calls, and a dev Mix task that drains the buffer through that
# test helper (test support compiled into :dev). The Mix task running
# the helper does not make flush/0 product code: the finding stays
# anchored at the cancel the product runs, not the test-only one.
defmodule Excl.Mailbox.TestOnlyFlush.WriteBuffer do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
  def insert(row), do: GenServer.cast(__MODULE__, {:insert, row})
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(_), do: {:ok, %{buffer: [], timer: Process.send_after(self(), :tick, 1000)}}

  @impl true
  def handle_cast({:insert, row}, s) do
    buf = [row | s.buffer]

    if length(buf) >= 100 do
      Process.cancel_timer(s.timer)
      write(buf)
      {:noreply, %{s | buffer: [], timer: Process.send_after(self(), :tick, 1000)}}
    else
      {:noreply, %{s | buffer: buf}}
    end
  end

  @impl true
  def handle_call(:flush, _from, s) do
    Process.cancel_timer(s.timer)
    write(s.buffer)
    {:reply, :ok, %{s | buffer: [], timer: Process.send_after(self(), :tick, 1000)}}
  end

  @impl true
  def handle_info(:tick, s) do
    write(s.buffer)
    {:noreply, %{s | buffer: [], timer: Process.send_after(self(), :tick, 1000)}}
  end

  defp write(rows), do: :persistent_term.put(__MODULE__, rows)
end

defmodule Excl.Mailbox.TestOnlyFlush.BufferTestSupport do
  @moduledoc false
  # Test support compiled with the program: it calls into ExUnit, and it
  # is flush/0's only caller.
  def drain do
    ExUnit.Callbacks.on_exit(fn -> :ok end)
    Excl.Mailbox.TestOnlyFlush.WriteBuffer.flush()
  end
end

defmodule Mix.Tasks.Excl.Mailbox.TestOnlyFlush.Drain do
  @moduledoc false
  use Mix.Task

  @shortdoc "Drains the write buffer"
  @impl true
  def run(_args), do: Excl.Mailbox.TestOnlyFlush.BufferTestSupport.drain()
end

# Real bugs a removed exclusion used to hide.

# The :poll clause arms a local :poll watchdog around a blocking fetch
# and cancels it after. A :poll the watchdog delivered while the fetch
# blocked is taken as the next poll: the clause runs twice. The clause
# taking the same message is no excuse, since this timer was armed after
# the message being handled arrived.
defmodule Excl.Mailbox.OwnClauseWatchdog.Poller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :poll)
    {:ok, %{url: Keyword.fetch!(opts, :url), last: nil}}
  end

  @impl true
  def handle_info(:poll, s) do
    ref = Process.send_after(self(), :poll, 30_000)
    body = fetch(s.url)
    Process.cancel_timer(ref)
    Process.send_after(self(), :poll, 1_000)
    {:noreply, %{s | last: body}}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp fetch(url), do: :httpc.request(String.to_charlist(url))
end

# The :drain clause arms the next :drain on every path, and when a
# backlog is left it runs the clause again at once by calling
# handle_info(:drain, s) itself: the inner run arms another :drain, so
# every backlogged tick adds a timer.
defmodule Excl.Mailbox.DrainReentersItself.Drainer do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :drain, 1_000)
    {:ok, %{queue: :queue.new()}}
  end

  @impl true
  def handle_info(:drain, s) do
    Process.send_after(self(), :drain, 1_000)
    s = drain_some(s)

    if :queue.is_empty(s.queue) do
      {:noreply, s}
    else
      handle_info(:drain, s)
    end
  end

  def handle_info(_msg, s), do: {:noreply, s}

  defp drain_some(s), do: %{s | queue: :queue.drop(s.queue)}
end
