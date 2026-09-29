# Cases for blocking exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/blocking_test.exs.

# Five servers. Gateway's :quote request reaches Ledger by two paths:
# through Pricing's :price (a static call by name) and through
# Inventory's :reserve, which calls Ledger on a pid it was handed (the
# :balance tag attributes it). Inventory's :reserve and Warehouse's
# :stock call each other: a call cycle, the cycle's own finding. The
# chain Gateway -> Ledger is reported once, through Pricing, as static:
# the path through the cycle is the cycle's, not a second chain.
defmodule Excl.Blocking.CycleOnPath.Ledger do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @impl true
  def init(s), do: {:ok, s}
  @impl true
  def handle_call(:balance, _from, s), do: {:reply, Map.get(s, :balance, 0), s}
end

defmodule Excl.Blocking.CycleOnPath.Pricing do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @impl true
  def init(s), do: {:ok, s}
  @impl true
  def handle_call(:price, _from, s) do
    balance = GenServer.call(Excl.Blocking.CycleOnPath.Ledger, :balance)
    {:reply, balance * 2, s}
  end
end

defmodule Excl.Blocking.CycleOnPath.Warehouse do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @impl true
  def init(s), do: {:ok, s}
  @impl true
  def handle_call(:stock, _from, s) do
    {:reply, GenServer.call(Excl.Blocking.CycleOnPath.Inventory, :reserve), s}
  end
end

defmodule Excl.Blocking.CycleOnPath.Inventory do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{ledger: nil}, name: __MODULE__)
  @impl true
  def init(s), do: {:ok, s}
  @impl true
  def handle_call(:reserve, _from, %{ledger: ledger} = s) do
    stock = GenServer.call(Excl.Blocking.CycleOnPath.Warehouse, :stock)
    balance = GenServer.call(ledger, :balance)
    {:reply, {stock, balance}, s}
  end

  def handle_call({:ledger, pid}, _from, s), do: {:reply, :ok, %{s | ledger: pid}}
end

defmodule Excl.Blocking.CycleOnPath.Gateway do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  @impl true
  def init(s), do: {:ok, s}
  @impl true
  def handle_call(:quote, _from, s) do
    reserved = GenServer.call(Excl.Blocking.CycleOnPath.Inventory, :reserve)
    price = GenServer.call(Excl.Blocking.CycleOnPath.Pricing, :price)
    {:reply, {reserved, price}, s}
  end
end

# A server whose handle_call/3 answers from its state at once,
# summarizing its entries through a remote capture of its own module
# (`&__MODULE__.format/1`, an external fun). A peer calls it with
# :infinity from its own handle_call/3. The hop cannot hang the caller:
# the fun handed to Enum.map is this module's code, walked like any
# other of its functions.
defmodule Excl.Blocking.OwnCapture.Directory do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def entries, do: GenServer.call(__MODULE__, :entries, :infinity)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:entries, _from, state) do
    {:reply, Enum.map(state, &__MODULE__.format/1), state}
  end

  def format({k, v}), do: {k, map_size(v)}
end

defmodule Excl.Blocking.OwnCapture.Frontend do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Excl.Blocking.OwnCapture.Directory.entries(), state}
  end
end

# The same directory summarizing through a capture of another module's
# function: what that fun does is not the directory's code, so the
# :infinity call into it may wait on anything. What the own capture
# above is not.
defmodule Excl.Blocking.ForeignCapture.Directory do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def entries, do: GenServer.call(__MODULE__, :entries, :infinity)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:entries, _from, state) do
    {:reply, Enum.map(state, &Excl.Blocking.ForeignCapture.Format.format/1), state}
  end
end

defmodule Excl.Blocking.ForeignCapture.Format do
  @moduledoc false
  def format({k, v}), do: {k, map_size(v)}
end

defmodule Excl.Blocking.ForeignCapture.Frontend do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, Excl.Blocking.ForeignCapture.Directory.entries(), state}
  end
end

# An rpc whose closure reads process info on the peer through a remote
# capture of its own module (`&__MODULE__.summary/1`). What the closure
# runs is this module's code, which answers at once: the rpc's default
# :infinity timeout is no hang.
defmodule Excl.Blocking.OwnCaptureRpc.ClusterInfo do
  @moduledoc false
  def counts(node) do
    :erpc.call(node, fn -> Enum.map(Process.list(), &__MODULE__.summary/1) end)
  end

  def summary(pid), do: Process.info(pid, :message_queue_len)
end

# The same rpc through a capture of another module's function, whose
# code the closure does not own: the default :infinity timeout may wait
# on it forever. What the own capture above is not.
defmodule Excl.Blocking.ForeignCaptureRpc.ClusterInfo do
  @moduledoc false
  def counts(node) do
    :erpc.call(node, fn ->
      Enum.map(Process.list(), &Excl.Blocking.ForeignCaptureRpc.Summary.summary/1)
    end)
  end
end

defmodule Excl.Blocking.ForeignCaptureRpc.Summary do
  @moduledoc false
  def summary(pid), do: Process.info(pid, :message_queue_len)
end

# A server runs a job in a monitored worker under a deadline timer. When
# the job reports back, handle_info cancels the deadline; if the cancel
# says the timer already fired, its :deadline message is in the mailbox
# and the receive that drops it (or the worker's :DOWN) returns at once.
# A flush, not a wait.
defmodule Excl.Blocking.FlushWithDown.Runner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:run, job}, _from, state) do
    worker = spawn(fn -> job.() end)
    timer = Process.send_after(self(), :deadline, 5_000)
    {:reply, :ok, Map.merge(state, %{worker: worker, timer: timer})}
  end

  @impl true
  def handle_info({:done, result}, %{worker: worker, timer: timer} = state) do
    ref = Process.monitor(worker)

    case Process.cancel_timer(timer) do
      false ->
        receive do
          :deadline -> :ok
          {:DOWN, ^ref, :process, _, _} -> :ok
        end

      _ ->
        :ok
    end

    {:noreply, Map.put(state, :result, result)}
  end

  def handle_info(:deadline, state), do: {:noreply, state}
end

# The same runner waiting whatever the cancel said: when the timer had
# not fired, the cancel stops it, and handle_info/2 holds the server
# until the worker exits. The wait the flush above is not.
defmodule Excl.Blocking.WaitWithDown.Runner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:run, job}, _from, state) do
    worker = spawn(fn -> job.() end)
    timer = Process.send_after(self(), :deadline, 5_000)
    {:reply, :ok, Map.merge(state, %{worker: worker, timer: timer})}
  end

  @impl true
  def handle_info({:done, result}, %{worker: worker, timer: timer} = state) do
    ref = Process.monitor(worker)
    Process.cancel_timer(timer)

    receive do
      :deadline -> :ok
      {:DOWN, ^ref, :process, _, _} -> :ok
    end

    {:noreply, Map.put(state, :result, result)}
  end

  def handle_info(:deadline, state), do: {:noreply, state}
end

# A trapping server runs an external command through a port under a
# deadline timer. When the port reports its exit status, handle_call
# cancels the deadline; if the cancel says the timer already fired, its
# :deadline message is in the mailbox and the receive that drops it (or
# the port's :EXIT) returns at once. A flush, not a wait.
defmodule Excl.Blocking.FlushWithExit.Command do
  @moduledoc false
  use GenServer

  def start_link(cmd), do: GenServer.start_link(__MODULE__, cmd, name: __MODULE__)

  @impl true
  def init(cmd) do
    Process.flag(:trap_exit, true)
    {:ok, %{cmd: cmd}}
  end

  @impl true
  def handle_call(:run, _from, %{cmd: cmd} = state) do
    port = Port.open({:spawn, cmd}, [:exit_status])
    timer = Process.send_after(self(), :deadline, 5_000)

    receive do
      {^port, {:exit_status, status}} ->
        case Process.cancel_timer(timer) do
          false ->
            receive do
              :deadline -> :ok
              {:EXIT, ^port, _} -> :ok
            end

          _ ->
            :ok
        end

        {:reply, status, state}
    after
      5_000 -> {:reply, :timeout, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

# The same command server waiting whatever the cancel said: when the
# timer had not fired, handle_call/3 holds the server until the port's
# :EXIT. The wait the flush above is not.
defmodule Excl.Blocking.WaitWithExit.Command do
  @moduledoc false
  use GenServer

  def start_link(cmd), do: GenServer.start_link(__MODULE__, cmd, name: __MODULE__)

  @impl true
  def init(cmd) do
    Process.flag(:trap_exit, true)
    {:ok, %{cmd: cmd}}
  end

  @impl true
  def handle_call(:run, _from, %{cmd: cmd} = state) do
    port = Port.open({:spawn, cmd}, [:exit_status])
    timer = Process.send_after(self(), :deadline, 5_000)

    receive do
      {^port, {:exit_status, status}} ->
        Process.cancel_timer(timer)

        receive do
          :deadline -> :ok
          {:EXIT, ^port, _} -> :ok
        end

        {:reply, status, state}
    after
      5_000 -> {:reply, :timeout, state}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end

# A cast handler that prices the headline item directly and the rest
# through Enum.map with a capture of the same client function: one
# callee, called and handed. The chain to the catalog is one chain,
# reported once.
defmodule Excl.Blocking.CalledAndHanded.Catalog do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def price(sku), do: GenServer.call(__MODULE__, {:price, sku})

  @impl true
  def init(prices), do: {:ok, prices}

  @impl true
  def handle_call({:price, sku}, _from, prices), do: {:reply, Map.get(prices, sku, 0), prices}
end

defmodule Excl.Blocking.CalledAndHanded.Cart do
  @moduledoc false
  use GenServer
  alias Excl.Blocking.CalledAndHanded.Catalog

  def start_link(_),
    do: GenServer.start_link(__MODULE__, %{items: [], total: 0}, name: __MODULE__)

  def reprice(headline), do: GenServer.cast(__MODULE__, {:reprice, headline})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_cast({:reprice, headline}, %{items: items} = state) do
    first = Catalog.price(headline)
    rest = Enum.map(items, &Catalog.price/1)
    {:noreply, %{state | total: first + Enum.sum(rest)}}
  end
end

# An exporter whose export job runs either in a worker process
# (start_worker/1 starts a Task on the fun it is handed) or inline in
# the server (run_inline/1). The job waits for the sink's ack with a
# bare receive: on the inline path that receive blocks handle_call/3. A
# real hang the analysis must keep reporting, though the same closure
# also runs elsewhere.
defmodule Excl.Blocking.HandedAndInline.Exporter do
  @moduledoc false
  use GenServer

  def start_link(sink), do: GenServer.start_link(__MODULE__, sink, name: __MODULE__)
  def export(rows, async?), do: GenServer.call(__MODULE__, {:export, rows, async?})

  @impl true
  def init(sink), do: {:ok, sink}

  @impl true
  def handle_call({:export, rows, async?}, _from, sink) do
    job = fn ->
      send(sink, {:rows, self(), rows})

      receive do
        {:ack, ^sink} -> :ok
      end
    end

    if async?, do: start_worker(job), else: run_inline(job)
    {:reply, :ok, sink}
  end

  defp start_worker(fun), do: Task.start(fun)

  defp run_inline(fun) do
    fun.()
  end
end

# As above, but the inline path calls the job itself (job.()), which the
# compiler turns into a direct call of the closure: the receive blocks
# handle_call/3 on that path, a real hang the analysis must keep
# reporting.
defmodule Excl.Blocking.HandedAndCalled.Exporter do
  @moduledoc false
  use GenServer

  def start_link(sink), do: GenServer.start_link(__MODULE__, sink, name: __MODULE__)
  def export(rows, async?), do: GenServer.call(__MODULE__, {:export, rows, async?})

  @impl true
  def init(sink), do: {:ok, sink}

  @impl true
  def handle_call({:export, rows, async?}, _from, sink) do
    job = fn ->
      send(sink, {:rows, self(), rows})

      receive do
        {:ack, ^sink} -> :ok
      end
    end

    if async?, do: start_worker(job), else: job.()
    {:reply, :ok, sink}
  end

  defp start_worker(fun), do: Task.start(fun)
end

# A poller whose tick message is chosen at run time (:tick or
# :fast_tick), beside a literal :cleanup timer. Changing the rate
# cancels the tick timer and, when cancel_timer says it already fired,
# flushes its message: the receive's clauses name the two tick messages,
# which the module arms only through a variable. The analysis cannot
# tell the flush misses the timer's message, so it is a flush.
defmodule Excl.Blocking.RuntimeTick.Poller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def set_rate(rate), do: GenServer.call(__MODULE__, {:set_rate, rate})

  @impl true
  def init(_opts) do
    Process.send_after(self(), :cleanup, 60_000)
    {:ok, %{rate: :normal, timer: arm(:normal)}}
  end

  @impl true
  def handle_call({:set_rate, rate}, _from, s) do
    if Process.cancel_timer(s.timer) == false do
      receive do
        :tick -> :ok
        :fast_tick -> :ok
      end
    end

    {:reply, :ok, %{s | rate: rate, timer: arm(rate)}}
  end

  @impl true
  def handle_info(:cleanup, s) do
    Process.send_after(self(), :cleanup, 60_000)
    {:noreply, s}
  end

  def handle_info(msg, s) when msg in [:tick, :fast_tick] do
    {:noreply, %{s | timer: arm(s.rate)}}
  end

  defp arm(rate) do
    msg = if rate == :fast, do: :fast_tick, else: :tick
    Process.send_after(self(), msg, if(rate == :fast, do: 100, else: 1000))
  end
end

# The same poller waiting for the tick whatever the cancel said: a
# cancelled timer never delivers, and handle_call/3 hangs. The wait the
# flush above is not.
defmodule Excl.Blocking.RuntimeTickWait.Poller do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def set_rate(rate), do: GenServer.call(__MODULE__, {:set_rate, rate})

  @impl true
  def init(_opts) do
    Process.send_after(self(), :cleanup, 60_000)
    {:ok, %{rate: :normal, timer: arm(:normal)}}
  end

  @impl true
  def handle_call({:set_rate, rate}, _from, s) do
    Process.cancel_timer(s.timer)

    receive do
      :tick -> :ok
      :fast_tick -> :ok
    end

    {:reply, :ok, %{s | rate: rate, timer: arm(rate)}}
  end

  @impl true
  def handle_info(:cleanup, s) do
    Process.send_after(self(), :cleanup, 60_000)
    {:noreply, s}
  end

  def handle_info(msg, s) when msg in [:tick, :fast_tick] do
    {:noreply, %{s | timer: arm(s.rate)}}
  end

  defp arm(rate) do
    msg = if rate == :fast, do: :fast_tick, else: :tick
    Process.send_after(self(), msg, if(rate == :fast, do: 100, else: 1000))
  end
end

# The poll timer's message was renamed :refresh -> :poll, but the
# cancel_timer flush in reschedule still waits for :refresh. When the
# timer had fired, the :poll in the mailbox never matches and the server
# hangs in handle_call/3: every timer message the module arms is known,
# and none is the receive's. A real hang the analysis must keep
# reporting.
defmodule Excl.Blocking.RenamedTick.Refresher do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def reschedule(ms), do: GenServer.call(__MODULE__, {:reschedule, ms})

  @impl true
  def init(_opts), do: {:ok, %{interval: 1000, timer: Process.send_after(self(), :poll, 1000)}}

  @impl true
  def handle_call({:reschedule, ms}, _from, s) do
    if Process.cancel_timer(s.timer) == false do
      receive do
        :refresh -> :ok
      end
    end

    {:reply, :ok, %{s | interval: ms, timer: Process.send_after(self(), :poll, ms)}}
  end

  @impl true
  def handle_info(:poll, s) do
    {:noreply, %{s | timer: Process.send_after(self(), :poll, s.interval)}}
  end
end
