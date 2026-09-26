# Soundness programs for the races analysis: real races each finding must
# keep. test/soundness/races_test.exs lists them, one test each.

# ── The census's counter-examples ─────────────────────────────────────

defmodule Argus.Test.Soundness.Races.JanitorCounter do
  # A counter that serializes its bumps in its own process, with a public
  # reset/1 its own handle_info calls too: the janitor's reset lands
  # between the counter's lookup and its insert, and the insert undoes it.
  use GenServer
  @tab :sound_janitor_counts

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public, :set])
    {:ok, o}
  end

  def bump(k), do: GenServer.call(__MODULE__, {:bump, k})
  def reset(k), do: :ets.insert(@tab, {k, 0})

  @impl true
  def handle_call({:bump, k}, _from, s) do
    n =
      case :ets.lookup(@tab, k) do
        [{^k, n}] -> n
        [] -> 0
      end

    :ets.insert(@tab, {k, n + 1})
    {:reply, n + 1, s}
  end

  @impl true
  def handle_info({:reset, k}, s) do
    reset(k)
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Races.Janitor do
  use GenServer

  def start_link(keys), do: GenServer.start_link(__MODULE__, keys, name: __MODULE__)

  @impl true
  def init(keys) do
    :timer.send_interval(60_000, :tick)
    {:ok, keys}
  end

  @impl true
  def handle_info(:tick, keys) do
    Enum.each(keys, fn k -> Argus.Test.Soundness.Races.JanitorCounter.reset(k) end)
    {:noreply, keys}
  end
end

# ── Concurrency: another process runs the writer ──────────────────────

defmodule Argus.Test.Soundness.Races.DirectJanitor do
  # The counter of JanitorCounter's shape, and a janitor that calls
  # reset/1 directly.
  use GenServer
  @tab :sound_direct_counts

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public, :set])
    {:ok, o}
  end

  def reset(k), do: :ets.insert(@tab, {k, 0})

  @impl true
  def handle_call({:bump, k}, _from, s) do
    n =
      case :ets.lookup(@tab, k) do
        [{^k, n}] -> n
        [] -> 0
      end

    :ets.insert(@tab, {k, n + 1})
    {:reply, n + 1, s}
  end

  @impl true
  def handle_info({:reset, k}, s) do
    reset(k)
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Races.DirectJanitorServer do
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_info({:reset, k}, s) do
    Argus.Test.Soundness.Races.DirectJanitor.reset(k)
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Races.TimerReset do
  # The counter arms a timer that resets a key in a process of its own
  # (apply_after): the reset lands between the counter's read and write.
  use GenServer
  @tab :sound_timer_counts

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public, :set])
    {:ok, o}
  end

  def reset(k), do: :ets.insert(@tab, {k, 0})

  @impl true
  def handle_call({:bump, k}, _from, s) do
    n =
      case :ets.lookup(@tab, k) do
        [{^k, n}] -> n
        [] -> 0
      end

    :ets.insert(@tab, {k, n + 1})
    {:ok, _} = :timer.apply_after(60_000, __MODULE__, :reset, [k])
    {:reply, n + 1, s}
  end
end

defmodule Argus.Test.Soundness.Races.LibraryReset do
  # A library's counter, serialized in its server, with reset/1 its users
  # call from their own processes and its own handle_info calls too.
  use GenServer
  @tab :sound_library_counts

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public, :set])
    {:ok, o}
  end

  def reset(k), do: :ets.insert(@tab, {k, 0})

  @impl true
  def handle_call({:bump, k}, _from, s) do
    n =
      case :ets.lookup(@tab, k) do
        [{^k, n}] -> n
        [] -> 0
      end

    :ets.insert(@tab, {k, n + 1})
    {:reply, n + 1, s}
  end

  @impl true
  def handle_info({:reset, k}, s) do
    reset(k)
    {:noreply, s}
  end
end

# ── Quiet controls: no rival, or no harm ──────────────────────────────

defmodule Argus.Test.Soundness.Races.CounterSelf do
  # A counter only its own process writes: no rival.
  use GenServer
  @tab :sound_counter_self

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public, :set])
    {:ok, o}
  end

  def bump(k), do: GenServer.call(__MODULE__, {:bump, k})

  @impl true
  def handle_call({:bump, k}, _from, s) do
    n =
      case :ets.lookup(@tab, k) do
        [{^k, n}] -> n
        [] -> 0
      end

    :ets.insert(@tab, {k, n + 1})
    {:reply, n + 1, s}
  end
end
