# Cases for races exclusions and nearby defects that must remain reported.
# Asserted by test/exclusions/races_test.exs.

# A log sink two servers start lazily under one name. The start sits in
# a helper that returns its result, and ensure/1 reads that result
# without returning it: the loser of two callers that both saw no sink
# gets {:error, {:already_started, pid}} and raises a false "sink failed
# to start" alert. A real race the analysis must keep reporting.
defmodule Excl.Races.StartResultRead.Sink do
  @moduledoc false
  use GenServer

  def ensure(level) do
    if Process.whereis(__MODULE__) == nil do
      case start_sink(level) do
        {:ok, pid} -> greet(pid, level)
        error -> alert(error)
      end
    end

    :ok
  end

  defp alert(error), do: :telemetry.execute([:sink, :start_failed], %{}, %{error: error})

  defp start_sink(level), do: GenServer.start(__MODULE__, level, name: __MODULE__)
  defp greet(pid, level), do: GenServer.cast(pid, {:hello, level})

  @impl true
  def init(level), do: {:ok, level}

  @impl true
  def handle_cast({:hello, _}, s), do: {:noreply, s}
end

defmodule Excl.Races.StartResultRead.Web do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call({:log, level}, _from, s) do
    Excl.Races.StartResultRead.Sink.ensure(level)
    {:reply, :ok, s}
  end
end

defmodule Excl.Races.StartResultRead.Jobs do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_cast({:log, level}, s) do
    Excl.Races.StartResultRead.Sink.ensure(level)
    {:noreply, s}
  end
end

# Metered usage over a table the library's users hand in: the total is
# read, the call's cost computed, and a helper writes the old total plus
# the cost. Two callers that read the same total each write their own
# sum, and one call's cost is lost: a real lost update the analysis must
# keep reporting, though the write is in a helper.
defmodule Excl.Races.HandedTableCharge do
  @moduledoc false
  @spec charge(:ets.table(), term(), map()) :: :ok
  def charge(table, key, req) do
    case :ets.lookup(table, key) do
      [{^key, total}] -> put_total(table, key, total + cost(req))
      _ -> put_total(table, key, cost(req))
    end

    :ok
  end

  defp cost(%{bytes: b}), do: div(b, 1024) + 1
  defp put_total(table, key, total), do: :ets.insert(table, {key, total})
end

# A hit counter over a table the library's users hand in (Hammer's
# hit(table, key, ...)): the count is read, then written back plus one
# by a helper. Two callers that read the same count each write n + 1,
# and one hit is lost: a real lost update the analysis must keep
# reporting.
defmodule Excl.Races.HandedTableHits do
  @moduledoc false
  @spec hit(:ets.table(), term()) :: :ok
  def hit(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] -> put_count(table, key, n + 1)
      _ -> put_count(table, key, 1)
    end

    :ok
  end

  defp put_count(table, key, n), do: :ets.insert(table, {key, n})
end

# A library that bumps a generation row in a table its user hands in,
# from one sweeper process it spawns for the table. The sweeper is the
# only writer the library has: its lookup-then-insert is serialized in
# its own process, and a race needs a writer the program does not show.
defmodule Excl.Races.SingleSweeper do
  @moduledoc false
  def start(table), do: spawn(__MODULE__, :loop, [table])

  def loop(table) do
    receive do
      :tick ->
        case :ets.lookup(table, :generation) do
          [{:generation, g}] -> :ets.insert(table, {:generation, g + 1})
          _ -> :ets.insert(table, {:generation, 1})
        end

        loop(table)
    end
  end
end

# The same lookup-then-insert on a handed table, run by whichever
# process calls bump/1: two callers that read the same generation each
# write g + 1. The race the single sweeper above cannot have.
defmodule Excl.Races.OpenBump do
  @moduledoc false
  @spec bump(:ets.table()) :: :ok
  def bump(table) do
    case :ets.lookup(table, :generation) do
      [{:generation, g}] -> :ets.insert(table, {:generation, g + 1})
      _ -> :ets.insert(table, {:generation, 1})
    end

    :ok
  end
end

# One table maps each way: a name's row holds its id, and the id's row
# holds the name back. register/1 publishes the id under the name before
# the id's own row exists. id_of/1 reads the name's row, which is
# written first: it cannot meet the gap. (name_of/1 can, with badarg;
# that true window stays hidden too, as the census recorded: with one
# table the rule cannot tell the two rows apart.)
defmodule Excl.Races.TwoWayOneTable do
  @moduledoc false
  def start, do: :ets.new(:excl_races_names, [:named_table, :public, read_concurrency: true])

  def register(name) when is_binary(name) do
    id = System.unique_integer([:positive])
    :ets.insert(:excl_races_names, {name, id})
    :ets.insert(:excl_races_names, {id, name})
    id
  end

  def id_of(name), do: :ets.lookup_element(:excl_races_names, name, 2)
  def name_of(id), do: :ets.lookup_element(:excl_races_names, id, 2)
end

# The same map over two public named tables: register/1 publishes the id
# under the name before the id's row exists, and name_of/1 in another
# process meets the gap with badarg. The publish-order bug the rule is
# about.
defmodule Excl.Races.TwoWayTwoTables do
  @moduledoc false
  def start do
    :ets.new(:excl_races_forward, [:named_table, :public, read_concurrency: true])
    :ets.new(:excl_races_reverse, [:named_table, :public, read_concurrency: true])
  end

  def register(name) when is_binary(name) do
    id = System.unique_integer([:positive])
    :ets.insert(:excl_races_forward, {name, id})
    :ets.insert(:excl_races_reverse, {id, name})
    id
  end

  def id_of(name), do: :ets.lookup_element(:excl_races_forward, name, 2)
  def name_of(id), do: :ets.lookup_element(:excl_races_reverse, id, 2)
end

# A two-way interning map a process keeps for itself: names to ids and
# ids back to names, in two private tables handed around in one map.
# intern/2 publishes the id under the name before the id's row exists,
# but only the owning process can read either table, so no reader can
# meet the gap.
defmodule Excl.Races.PrivateInterner do
  @moduledoc false
  def new do
    %{
      forward: :ets.new(:excl_races_private_forward, [:set, :private]),
      reverse: :ets.new(:excl_races_private_reverse, [:set, :private])
    }
  end

  def intern(%{forward: f, reverse: r}, name) when is_binary(name) do
    id = System.unique_integer([:positive])
    :ets.insert(f, {name, id})
    :ets.insert(r, {id, name})
    id
  end

  def id_of(%{forward: f}, name), do: :ets.lookup_element(f, name, 2)
  def name_of(%{reverse: r}, id), do: :ets.lookup_element(r, id, 2)
end

# The same interner over public tables: another process handed the map
# can read the reverse table in the gap and crash with badarg. The bug
# the private tables above rule out.
defmodule Excl.Races.PublicInterner do
  @moduledoc false
  def new do
    %{
      forward: :ets.new(:excl_races_public_forward, [:set, :public]),
      reverse: :ets.new(:excl_races_public_reverse, [:set, :public])
    }
  end

  def intern(%{forward: f, reverse: r}, name) when is_binary(name) do
    id = System.unique_integer([:positive])
    :ets.insert(f, {name, id})
    :ets.insert(r, {id, name})
    id
  end

  def id_of(%{forward: f}, name), do: :ets.lookup_element(f, name, 2)
  def name_of(%{reverse: r}, id), do: :ets.lookup_element(r, id, 2)
end

# One server bumps a quota record with dirty operations under a :global
# lock; an admin server resets it under the same lock. The quota server
# is the only process that runs the read-modify-write, and the other
# writer holds the lock too: serialized.
defmodule Excl.Races.LockedQuota.Quota do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call({:use, account}, _from, s) do
    left =
      :global.trans({:excl_races_quota, account}, fn ->
        case :mnesia.dirty_read(:excl_races_quota, account) do
          [{:excl_races_quota, ^account, n}] when n > 0 ->
            :mnesia.dirty_write({:excl_races_quota, account, n - 1})
            n - 1

          _ ->
            0
        end
      end)

    {:reply, left, s}
  end
end

defmodule Excl.Races.LockedQuota.Admin do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_cast({:reset, account, n}, s) do
    :global.trans({:excl_races_quota, account}, fn ->
      :mnesia.dirty_write({:excl_races_quota, account, n})
    end)

    {:noreply, s}
  end
end

# The same quota whose admin resets it without the lock: a reset that
# lands between the quota server's read and write is lost. The race the
# locked admin above cannot have.
defmodule Excl.Races.UnlockedQuota.Quota do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_call({:use, account}, _from, s) do
    left =
      :global.trans({:excl_races_open_quota, account}, fn ->
        case :mnesia.dirty_read(:excl_races_open_quota, account) do
          [{:excl_races_open_quota, ^account, n}] when n > 0 ->
            :mnesia.dirty_write({:excl_races_open_quota, account, n - 1})
            n - 1

          _ ->
            0
        end
      end)

    {:reply, left, s}
  end
end

defmodule Excl.Races.UnlockedQuota.Admin do
  @moduledoc false
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_cast({:reset, account, n}, s) do
    :mnesia.dirty_write({:excl_races_open_quota, account, n})
    {:noreply, s}
  end
end

# A cluster-wide sequence in Mnesia, bumped with dirty operations under
# a :global lock: the read and the write run in the closure
# :global.trans/2 runs, and the private helper that writes is called
# only from that closure. Every writer of the table holds the lock, so
# the dirty read-modify-write is serialized.
defmodule Excl.Races.LockedSequence do
  @moduledoc false
  def next(name) do
    :global.trans({:excl_races_seq, name}, fn ->
      n =
        case :mnesia.dirty_read(:excl_races_seq, name) do
          [{:excl_races_seq, ^name, n}] -> n
          _ -> 0
        end

      save({:excl_races_seq, name, n + 1})
      n + 1
    end)
  end

  defp save(rec), do: :mnesia.dirty_write(rec)
end

# The same sequence whose writing helper reset/1 also calls, outside the
# lock: a reset between the locked read and write is lost. The race the
# sequence above, whose helper only the locked closure calls, cannot
# have.
defmodule Excl.Races.LeakySequence do
  @moduledoc false
  def next(name) do
    :global.trans({:excl_races_leaky_seq, name}, fn ->
      n =
        case :mnesia.dirty_read(:excl_races_leaky_seq, name) do
          [{:excl_races_leaky_seq, ^name, n}] -> n
          _ -> 0
        end

      save({:excl_races_leaky_seq, name, n + 1})
      n + 1
    end)
  end

  def reset(name), do: save({:excl_races_leaky_seq, name, 0})

  defp save(rec), do: :mnesia.dirty_write(rec)
end

# A counter kept in a Mnesia table the caller names, bumped with dirty
# operations: the record is read, and a helper writes the record back
# with the count plus one. Two callers that read the same count each
# write n + 1, and one bump is lost: a real lost update the analysis must
# keep reporting, though the write is in a helper.
defmodule Excl.Races.HandedRecordCounter.Counters do
  @moduledoc false
  @spec bump(atom(), term()) :: :ok
  def bump(table, key) do
    case :mnesia.dirty_read(table, key) do
      [{^table, ^key, n}] -> save({table, key, n + 1})
      _ -> save({table, key, 1})
    end

    :ok
  end

  defp save(rec), do: :mnesia.dirty_write(rec)
end

defmodule Excl.Races.HandedRecordCounter.Web do
  @moduledoc false
  def page_view(page), do: Excl.Races.HandedRecordCounter.Counters.bump(:excl_races_views, page)
end

# ztlp's serial check over dirty Mnesia: a record is replaced only by a
# newer serial. Two writers that both read serial 3, one holding 4 and
# one 5, both pass the check, and 4 can land last: the older serial
# wins. A real race the analysis must keep reporting, as guarded.
defmodule Excl.Races.SerialCheck do
  @moduledoc false
  @spec record(term(), non_neg_integer()) :: :ok
  def record(key, serial) do
    case :mnesia.dirty_read(:excl_races_serials, key) do
      [{:excl_races_serials, ^key, cur}] when cur >= serial -> :ok
      _ -> :mnesia.dirty_write({:excl_races_serials, key, serial})
    end

    :ok
  end
end

# An idempotent ensure-default over dirty Mnesia: a user with no prefs
# record gets the defaults. Two racers that both find nothing both write
# the same defaults, and the function answers :ok whatever happened (its
# spec says so): no caller can act on who won, so it is no claim.
defmodule Excl.Races.EnsureDefault do
  @moduledoc false
  @defaults %{theme: :light, digest: :weekly}

  @spec ensure(term()) :: :ok
  def ensure(user) do
    case :mnesia.dirty_read(:excl_races_prefs, user) do
      [] -> :mnesia.dirty_write({:excl_races_prefs, user, @defaults})
      [_prefs] -> :ok
    end

    :ok
  end
end

# The same ensure answering whether it created the record: two racers
# that both find nothing both answer :created, and a caller that acts on
# it (sends the welcome mail) acts twice. The claim the constant answer
# above rules out.
defmodule Excl.Races.EnsureCreated do
  @moduledoc false
  @defaults %{theme: :light, digest: :weekly}

  @spec ensure(term()) :: :created | :exists
  def ensure(user) do
    case :mnesia.dirty_read(:excl_races_created_prefs, user) do
      [] ->
        :mnesia.dirty_write({:excl_races_created_prefs, user, @defaults})
        :created

      [_prefs] ->
        :exists
    end
  end
end

# Visits counted per account, found by the email index: the found branch
# writes the account back with its count plus one (a lost update between
# two racers that read the same count); the miss branch makes a new
# account under a fresh id (a duplicate between two racers that both
# find none). Only the miss branch's insert is the duplicate.
defmodule Excl.Races.IndexVisit do
  @moduledoc false
  @spec visit(String.t()) :: :ok
  def visit(email) do
    case :mnesia.dirty_index_read(:excl_races_accounts, email, :email) do
      [{:excl_races_accounts, id, ^email, n}] ->
        :mnesia.dirty_write({:excl_races_accounts, id, email, n + 1})

      _ ->
        :mnesia.dirty_write({:excl_races_accounts, System.unique_integer([:positive]), email, 1})
    end

    :ok
  end
end

# A cache warmer over dirty Mnesia: a page with no stored render is
# rendered and stored, and the warmer answers :miss or :hit for the
# hit-rate metric. Two racers that both miss both render the same page
# and store it: a fill, not a claim, whatever the caller does with the
# answer.
defmodule Excl.Races.Prerender do
  @moduledoc false
  @spec warm(String.t()) :: :hit | :miss
  def warm(page) do
    case :mnesia.dirty_read(:excl_races_pages, page) do
      [_stored] ->
        :hit

      _ ->
        html = render(page)
        :mnesia.dirty_write({:excl_races_pages, page, html})
        :miss
    end
  end

  def warm_all(pages) do
    misses = Enum.count(pages, fn p -> warm(p) == :miss end)
    :telemetry.execute([:prerender, :warm], %{misses: misses}, %{})
  end

  defp render(page), do: Enum.join(["<h1>", page, "</h1>"])
end
