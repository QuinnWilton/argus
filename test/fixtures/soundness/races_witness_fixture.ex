# The races harm-witness model's soundness programs
# (docs/design/races.md): the census's four counter-examples, and for each
# narrowing the model makes, the nearest real bugs it must still report.
# test/soundness/races_test.exs lists them, one test each.

# ── The census's counter-examples ─────────────────────────────────────

defmodule Argus.Test.Soundness.Races.AccessorChain do
  # mnesia_lib's val/set idiom on ETS: accessors take the key, and the
  # module's own count/0 and set_count/1 name one literal row through
  # them. incr/0 is a read-modify-write any number of callers run.
  @tab :sound_accessor_chain

  def start, do: :ets.new(@tab, [:named_table, :public, :set])

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{^k, v}] -> v
      [] -> 0
    end
  end

  def put(k, v), do: :ets.insert(@tab, {k, v})

  def count, do: get(:count)
  def set_count(v), do: put(:count, v)

  def incr, do: set_count(count() + 1)
end

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

defmodule Argus.Test.Soundness.Races.RegCache do
  # A bare cache process two servers start lazily under one name, each
  # with its own copy of the check.
  def loop(m) do
    receive do
      {:put, k, v} -> loop(Map.put(m, k, v))
    end
  end
end

defmodule Argus.Test.Soundness.Races.RegWeb do
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call({:remember, k, v}, _from, s) do
    if Process.whereis(:sound_reg_cache) == nil do
      Process.register(spawn(Argus.Test.Soundness.Races.RegCache, :loop, [%{}]), :sound_reg_cache)
    end

    send(:sound_reg_cache, {:put, k, v})
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Soundness.Races.RegJobs do
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_cast({:remember, k, v}, s) do
    if Process.whereis(:sound_reg_cache) == nil do
      Process.register(spawn(Argus.Test.Soundness.Races.RegCache, :loop, [%{}]), :sound_reg_cache)
    end

    send(:sound_reg_cache, {:put, k, v})
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Races.LeaseRelease do
  # A lease lock in Mnesia: acquire runs in a transaction and takes over
  # an expired lease; release checks the owner with a dirty read and
  # deletes with a dirty delete. Between the two the lease can expire and
  # another acquire commit: the delete removes the new owner's lock.
  @ttl 30_000

  def acquire(lock, me) do
    now = System.os_time(:millisecond)

    {:atomic, res} =
      :mnesia.transaction(fn ->
        case :mnesia.read(:sound_leases, lock, :write) do
          [] ->
            :mnesia.write({:sound_leases, lock, me, now + @ttl})
            :ok

          [{:sound_leases, ^lock, _, exp}] when exp < now ->
            :mnesia.write({:sound_leases, lock, me, now + @ttl})
            :ok

          _ ->
            {:error, :locked}
        end
      end)

    res
  end

  def release(lock, me) do
    case :mnesia.dirty_read(:sound_leases, lock) do
      [{:sound_leases, ^lock, ^me, _}] -> :mnesia.dirty_delete(:sound_leases, lock)
      _ -> :ok
    end
  end
end

# ── No witness, no race: the harms a pair must still show ─────────────

defmodule Argus.Test.Soundness.Races.TripOverCounter do
  # A default written blind on a row another process counts in: the
  # default lands over the counts made since the read.
  @tab :sound_trip_counts

  def start, do: :ets.new(@tab, [:named_table, :public])

  def ensure(k) do
    case :ets.lookup(@tab, k) do
      [] -> :ets.insert(@tab, {k, 0})
      _ -> :ok
    end

    :ok
  end

  def hit(k), do: :ets.update_counter(@tab, k, {2, 1}, {k, 0})
end

defmodule Argus.Test.Soundness.Races.PresenceTake do
  # A queue of callbacks taken by whoever finds one: both racers find it,
  # both delete it, both run it.
  @tab :sound_callbacks

  def start, do: :ets.new(@tab, [:named_table, :public])
  def put(id, fun), do: :ets.insert(@tab, {id, fun})

  def take(id) do
    case :ets.lookup(@tab, id) do
      [{_id, fun}] ->
        :ets.delete(@tab, id)
        {:ok, fun}

      [] ->
        :error
    end
  end
end

defmodule Argus.Test.Soundness.Races.VerdictClaim do
  # A slot claimed on first sight, the caller told whether it won.
  @tab :sound_slots

  def start, do: :ets.new(@tab, [:named_table, :public])

  def claim(slot) do
    case :ets.lookup(@tab, slot) do
      [] ->
        :ets.insert(@tab, {slot, self()})
        :claimed

      _ ->
        :taken
    end
  end
end

defmodule Argus.Test.Soundness.Races.FillFromStore do
  # Cache-aside over a Mnesia record, invalidated when the record
  # changes: a copy read before the change can land after the
  # invalidation, and the stale copy stays.
  @tab :sound_fill_cache

  def start, do: :ets.new(@tab, [:named_table, :public])

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{^k, v}] ->
        v

      [] ->
        [{:sound_settings, ^k, v}] = :mnesia.dirty_read(:sound_settings, k)
        :ets.insert(@tab, {k, v})
        v
    end
  end

  def update(k, v) do
    :mnesia.dirty_write({:sound_settings, k, v})
    :ets.delete(@tab, k)
  end
end

defmodule Argus.Test.Soundness.Races.GuardSerial do
  # A newest-wins row guarded by what it holds: both racers pass the
  # check, and the older serial can land last.
  @tab :sound_serials

  def start, do: :ets.new(@tab, [:named_table, :public])

  def put(k, serial) do
    case :ets.lookup(@tab, k) do
      [{^k, cur}] when cur >= serial -> :stale
      _ -> :ets.insert(@tab, {k, serial})
    end
  end
end

defmodule Argus.Test.Soundness.Races.LeaseReleaseEts do
  # The lease lock in ETS: release checks the owner, then deletes; a
  # takeover (select_replace of an expired lease) in between loses its
  # lock to the delete.
  @tab :sound_ets_leases

  def start, do: :ets.new(@tab, [:named_table, :public])

  def acquire(lock, me) do
    now = System.os_time(:millisecond)

    if :ets.insert_new(@tab, {lock, me, now + 30_000}),
      do: :ok,
      else: take_over(lock, me, now)
  end

  defp take_over(lock, me, now) do
    case :ets.lookup(@tab, lock) do
      [{^lock, _, exp}] when exp < now -> :ets.insert(@tab, {lock, me, now + 30_000})
      _ -> {:error, :locked}
    end
  end

  def release(lock, me) do
    case :ets.lookup(@tab, lock) do
      [{^lock, ^me, _}] -> :ets.delete(@tab, lock)
      _ -> :ok
    end
  end
end

defmodule Argus.Test.Soundness.Races.DeleteSends do
  # A job handed to a worker by whoever deletes its row first: both
  # racers see the row, both delete it, both hand it on.
  @tab :sound_jobs

  def start, do: :ets.new(@tab, [:named_table, :public])

  def dispatch(id, worker) do
    case :ets.lookup(@tab, id) do
      [{_id, job}] ->
        :ets.delete(@tab, id)
        send(worker, {:run, job})
        :ok

      [] ->
        :ok
    end
  end
end

# ── Keys: a rival is judged at the key it names ───────────────────────

defmodule Argus.Test.Soundness.Races.TotalsLib do
  # A library's running total, defaulted by a trip on a literal row, and
  # a public bump/1 its users call with any key: `bump(:total)` counts
  # into the row the default can land over.
  @tab :sound_totals

  def start, do: :ets.new(@tab, [:named_table, :public])

  def ensure_total do
    case :ets.lookup(@tab, :total) do
      [] -> :ets.insert(@tab, {:total, 0})
      _ -> :ok
    end

    :ok
  end

  def bump(k), do: :ets.update_counter(@tab, k, {2, 1}, {k, 0})
end

defmodule Argus.Test.Soundness.Races.TotalsEach do
  # The same default, and a server that bumps every key of a list through
  # a closure handed to Enum.each: which keys, the facts cannot say.
  use GenServer
  @tab :sound_totals_each

  def start_link(keys), do: GenServer.start_link(__MODULE__, keys, name: __MODULE__)

  @impl true
  def init(keys) do
    :ets.new(@tab, [:named_table, :public])
    {:ok, keys}
  end

  def ensure_total do
    case :ets.lookup(@tab, :total) do
      [] -> :ets.insert(@tab, {:total, 0})
      _ -> :ok
    end

    :ok
  end

  @impl true
  def handle_info(:tick, keys) do
    Enum.each(keys, fn k -> :ets.update_counter(@tab, k, {2, 1}, {k, 0}) end)
    {:noreply, keys}
  end
end

defmodule Argus.Test.Soundness.Races.TotalsLiteral do
  # The same default, and a server that counts into the very literal row.
  use GenServer
  @tab :sound_totals_literal

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public])
    {:ok, o}
  end

  def ensure_total do
    case :ets.lookup(@tab, :total) do
      [] -> :ets.insert(@tab, {:total, 0})
      _ -> :ok
    end

    :ok
  end

  @impl true
  def handle_info(:tick, s) do
    :ets.update_counter(@tab, :total, {2, 1}, {:total, 0})
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Races.AccessorOwner do
  # The accessor chain serialized in one server, and a second server that
  # resets the same literal row through the setter: the reset lands
  # between the owner's read and its write.
  use GenServer
  @tab :sound_accessor_owner

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public])
    {:ok, o}
  end

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{^k, v}] -> v
      [] -> 0
    end
  end

  def put(k, v), do: :ets.insert(@tab, {k, v})
  def count, do: get(:count)
  def set_count(v), do: put(:count, v)

  @impl true
  def handle_call(:incr, _from, s) do
    set_count(count() + 1)
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Soundness.Races.AccessorResetter do
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_info(:reset, s) do
    Argus.Test.Soundness.Races.AccessorOwner.set_count(0)
    {:noreply, s}
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

# ── Registry: another process claims the name ─────────────────────────

defmodule Argus.Test.Soundness.Races.RegServer do
  # A server that starts a named sink on first use, and a public ensure/0
  # its library's users call from their own processes.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call(:log, _from, s) do
    if Process.whereis(:sound_reg_sink) == nil do
      Process.register(spawn(Argus.Test.Soundness.Races.RegCache, :loop, [%{}]), :sound_reg_sink)
    end

    {:reply, :ok, s}
  end

  def ensure do
    if Process.whereis(:sound_reg_sink) == nil do
      Process.register(spawn(Argus.Test.Soundness.Races.RegCache, :loop, [%{}]), :sound_reg_sink)
    end

    :ok
  end
end

defmodule Argus.Test.Soundness.Races.RegTaskClaim do
  # A server whose handle_cast claims a name, and a task it starts per
  # message that claims the same name in a process of its own.
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_cast(:go, s) do
    if Process.whereis(:sound_reg_task) == nil do
      Process.register(spawn(Argus.Test.Soundness.Races.RegCache, :loop, [%{}]), :sound_reg_task)
    end

    Task.start(fn -> claim() end)
    {:noreply, s}
  end

  defp claim do
    Process.register(self(), :sound_reg_task)
  end
end

# ── Mnesia deletes: made on the record, over a record made again ───────

defmodule Argus.Test.Soundness.Races.LeaseReleaseDirty do
  # The lease lock with a dirty acquire: the release's delete takes the
  # lease another process just wrote.
  def acquire(lock, me) do
    case :mnesia.dirty_read(:sound_dirty_leases, lock) do
      [] -> :mnesia.dirty_write({:sound_dirty_leases, lock, me})
      _ -> {:error, :locked}
    end
  end

  def release(lock, me) do
    case :mnesia.dirty_read(:sound_dirty_leases, lock) do
      [{:sound_dirty_leases, ^lock, ^me}] -> :mnesia.dirty_delete(:sound_dirty_leases, lock)
      _ -> :ok
    end
  end
end

defmodule Argus.Test.Soundness.Races.SessionResume do
  # A session registered under a key a client presents again on resume:
  # the old process's cleanup, made on the owner it read, deletes the
  # new process's registration.
  def register(key, pid), do: :mnesia.dirty_write({:sound_sessions, key, pid})

  def unregister(key, pid) do
    case :mnesia.dirty_read(:sound_sessions, key) do
      [{:sound_sessions, ^key, ^pid}] -> :mnesia.dirty_delete(:sound_sessions, key)
      _ -> :ok
    end
  end
end

defmodule Argus.Test.Soundness.Races.RecordTake do
  # A record handed out by whoever deletes it: both racers take it.
  def take(id) do
    case :mnesia.dirty_read(:sound_record_jobs, id) do
      [{:sound_record_jobs, _id, job}] ->
        :mnesia.dirty_delete(:sound_record_jobs, id)
        {:ok, job}

      [] ->
        :error
    end
  end
end

# ── Stale fills: a copy of a source that can change ───────────────────

defmodule Argus.Test.Soundness.Races.FillViaServer do
  # A cache filled from a server's answer and invalidated when the server
  # is told the value changed.
  @tab :sound_fill_server

  def start, do: :ets.new(@tab, [:named_table, :public])

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{^k, v}] ->
        v

      [] ->
        v = GenServer.call(:sound_config_server, {:get, k})
        :ets.insert(@tab, {k, v})
        v
    end
  end

  def changed(k), do: :ets.delete(@tab, k)
end

defmodule Argus.Test.Soundness.Races.FillViaHelper do
  # The same, the source read by a project helper that reads a file.
  @tab :sound_fill_helper

  def start, do: :ets.new(@tab, [:named_table, :public])

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{^k, v}] ->
        v

      [] ->
        v = load(k)
        :ets.insert(@tab, {k, v})
        v
    end
  end

  def changed(k), do: :ets.delete(@tab, k)

  defp load(k), do: File.read!("/etc/sound/#{k}")
end

defmodule Argus.Test.Soundness.Races.FillOverUpdate do
  # A fill from Mnesia and an update that writes the new value straight
  # into the cache: the fill computed before the update lands after it.
  @tab :sound_fill_update

  def start, do: :ets.new(@tab, [:named_table, :public])

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{^k, v}] ->
        v

      [] ->
        [{:sound_prefs, ^k, v}] = :mnesia.dirty_read(:sound_prefs, k)
        :ets.insert(@tab, {k, v})
        v
    end
  end

  def put(k, v) do
    :mnesia.dirty_write({:sound_prefs, k, v})
    :ets.insert(@tab, {k, v})
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

defmodule Argus.Test.Soundness.Races.DefaultOnly do
  # A default two racers write alike, on a row nothing else writes, and a
  # decision that stays inside: no harm.
  @tab :sound_default_only

  def start, do: :ets.new(@tab, [:named_table, :public])

  def ensure(k) do
    case :ets.lookup(@tab, k) do
      [] -> :ets.insert(@tab, {k, :default})
      _ -> :ok
    end

    :ok
  end
end

defmodule Argus.Test.Soundness.Races.PureFill do
  # A refill that is a function of the key, invalidated: every copy is the
  # same, whenever it is made.
  @tab :sound_pure_fill

  def start, do: :ets.new(@tab, [:named_table, :public])

  def get(k) do
    case :ets.lookup(@tab, k) do
      [{_, v}] ->
        v

      [] ->
        v = render(k)
        :ets.insert(@tab, {k, v})
        v
    end
  end

  def invalidate(k), do: :ets.delete(@tab, k)

  defp render(k), do: {:rendered, k}
end
