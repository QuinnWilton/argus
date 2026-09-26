# Shapes the ets analysis keeps quiet (or keeps reported) through an
# exclusion no evaluation program exercises (census 2026-09-26); see
# `test/exclusions/ets_test.exs` and docs/design/exclusions.md.

# The server hands its cache to a keeper process it spawns and names
# itself the table's heir: when the keeper exits, the table comes back
# to the server instead of vanishing, so the keeper's end strands no
# reader.
defmodule Excl.Ets.HeirKeeper do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    parent = self()
    keeper = spawn(fn -> keep(parent) end)
    {:ok, %{keeper: keeper}}
  end

  defp keep(parent) do
    :ets.new(:excl_heir_keeper_cache, [:named_table, :public, :set, {:heir, parent, :keeper_gone}])

    receive do
      :stop -> :ok
    end
  end

  def lookup(key), do: :ets.lookup(:excl_heir_keeper_cache, key)

  @impl true
  def handle_info({:"ETS-TRANSFER", _tab, _from, :keeper_gone}, state), do: {:noreply, state}
end

# The same keeper without the heir: when the keeper exits its table goes
# with it, and every lookup after that raises. The bug the heir above
# prevents.
defmodule Excl.Ets.HeirlessKeeper do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    keeper = spawn(fn -> keep() end)
    {:ok, %{keeper: keeper}}
  end

  defp keep do
    :ets.new(:excl_heirless_keeper_cache, [:named_table, :public, :set])

    receive do
      :stop -> :ok
    end
  end

  def lookup(key), do: :ets.lookup(:excl_heirless_keeper_cache, key)
end

# A counter table two modules write, created with the OTP 25
# `write_concurrency: :auto` setting: the runtime picks the locking, so
# the table does have write concurrency.
defmodule Excl.Ets.AutoCounters do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:excl_auto_counters, [:named_table, :public, :set, {:write_concurrency, :auto}])
    {:ok, nil}
  end

  def bump(key), do: :ets.insert(:excl_auto_counters, {key, System.monotonic_time()})
end

defmodule Excl.Ets.AutoCounters.Reset do
  @moduledoc false
  def reset(key), do: :ets.insert(:excl_auto_counters, {key, 0})
end

# The same two writers over a table made with no write concurrency: its
# writers serialize on the table lock. What `:auto` above avoids.
defmodule Excl.Ets.LockedCounters do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:excl_locked_counters, [:named_table, :public, :set])
    {:ok, nil}
  end

  def bump(key), do: :ets.insert(:excl_locked_counters, {key, System.monotonic_time()})
end

defmodule Excl.Ets.LockedCounters.Reset do
  @moduledoc false
  def reset(key), do: :ets.insert(:excl_locked_counters, {key, 0})
end

# The server keeps its index in a named table named after the module;
# top/2, run by callers, sorts a batch in a scratch table it makes under
# the same atom, unnamed, and reads it back through the reference. That
# read is of the caller's own scratch table, not the server's, so no
# restart of the server can take it away. get/1 reads the server's table
# from the caller's process, which is the read the analysis is about.
defmodule Excl.Ets.ScratchUnderModuleName do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    {:ok, nil}
  end

  def put(key, value), do: :ets.insert(__MODULE__, {key, value})

  def get(key), do: :ets.lookup(__MODULE__, key)

  def top(rows, key) do
    scratch = :ets.new(__MODULE__, [:ordered_set])
    :ets.insert(scratch, rows)
    found = :ets.lookup(scratch, key)
    :ets.delete(scratch)
    found
  end
end

# A server whose table name comes from its options, created with a heir
# (the caller's registry process): the table outlives the server, so a
# reader in another process never meets it gone while the server
# restarts.
defmodule Excl.Ets.DynamicHeir do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    heir = Keyword.fetch!(opts, :heir)
    :ets.new(table, [:named_table, :public, :set, {:heir, heir, table}])
    {:ok, table}
  end

  def lookup(table, key), do: :ets.lookup(table, key)
end

# The same server without the heir: the table dies with it, and a
# reader that meets the restart raises. The bug the heir above prevents.
defmodule Excl.Ets.DynamicNoHeir do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    table = Keyword.fetch!(opts, :table)
    :ets.new(table, [:named_table, :public, :set])
    {:ok, table}
  end

  def lookup(table, key), do: :ets.lookup(table, key)
end

# start_link makes the named table through a helper that asks first, so
# the restart (start_link again, in the same supervisor) finds the table
# and leaves it (blockscout ContractCreator's guard, in a helper).
defmodule Excl.Ets.HelperAsks do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    ensure_table()
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  defp ensure_table do
    if :ets.whereis(:excl_helper_asks) == :undefined do
      :ets.new(:excl_helper_asks, [:named_table, :public, :set])
    end
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

# start_link asks :ets.whereis/1 and only then calls the helper that
# makes the named table: the guard in the start, the create in a helper.
# The restart finds the table and leaves it.
defmodule Excl.Ets.StartAsks do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    if :ets.whereis(:excl_start_asks) == :undefined, do: create_table()
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  defp create_table, do: :ets.new(:excl_start_asks, [:named_table, :public, :set])

  @impl true
  def init(opts), do: {:ok, opts}
end

# start_link starts the server, then a helper makes the named table and
# gives it to the server it started: the table dies with the server, so
# the restart's :ets.new finds the name free.
defmodule Excl.Ets.HelperGives do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    hand_table(pid)
    {:ok, pid}
  end

  defp hand_table(pid) do
    table = :ets.new(:excl_helper_gives, [:named_table, :public, :set])
    :ets.give_away(table, pid, :table)
  end

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, :table}, state), do: {:noreply, state}
end

# A helper makes the named table and start_link gives it to the server
# it starts (the create moved into a helper, the give-away left in the
# start): the table dies with the server, so the restart finds the name
# free.
defmodule Excl.Ets.StartGives do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    make_table()
    {:ok, pid} = GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    :ets.give_away(:excl_start_gives, pid, :table)
    {:ok, pid}
  end

  defp make_table, do: :ets.new(:excl_start_gives, [:named_table, :public, :set])

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, :table}, state), do: {:noreply, state}
end

# A helper start_link calls makes the named table, neither asking first
# nor giving it away: the table outlives a crashed server in the
# supervisor's process, and the restart's :ets.new raises on the name.
# The bug the four shapes above do not have.
defmodule Excl.Ets.HelperCreates do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    make_table()
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  defp make_table, do: :ets.new(:excl_helper_creates, [:named_table, :public, :set])

  @impl true
  def init(opts), do: {:ok, opts}
end

# A per-tenant supervisor keeps the tenant's routing table in a public
# table it creates in init/1. The application starts it inline for the
# default tenant, and Tenants.start/1 also starts one per extra tenant
# under a DynamicSupervisor, which restarts it: the table goes with each
# restart, and the worker's readers meet it gone. A supervisor some
# other supervisor starts is no application root, however the
# application also starts it.
defmodule Excl.Ets.TenantTable.App do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args), do: Excl.Ets.TenantTable.Sup.start_link(:default)
end

defmodule Excl.Ets.TenantTable.Sup do
  @moduledoc false
  use Supervisor

  def start_link(tenant), do: Supervisor.start_link(__MODULE__, tenant)

  @impl true
  def init(tenant) do
    :ets.new(:excl_tenant_routes, [:named_table, :public, :set])
    Supervisor.init([{Excl.Ets.TenantTable.Worker, tenant}], strategy: :one_for_one)
  end
end

defmodule Excl.Ets.TenantTable.Worker do
  @moduledoc false
  use GenServer

  def start_link(tenant), do: GenServer.start_link(__MODULE__, tenant)
  def route(key), do: :ets.lookup(:excl_tenant_routes, key)

  @impl true
  def init(tenant) do
    :ets.insert(:excl_tenant_routes, {tenant, self()})
    {:ok, tenant}
  end
end

defmodule Excl.Ets.TenantTable.Tenants do
  @moduledoc false
  def start(tenant),
    do: DynamicSupervisor.start_child(Excl.Ets.TenantPool, {Excl.Ets.TenantTable.Sup, tenant})
end
