defmodule Argus.Test.Fixtures.EtsOwner do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    table = :ets.new(:my_cache, [:set, :public, :named_table])
    {:ok, table}
  end
end

defmodule Argus.Test.Fixtures.EtsReader do
  @moduledoc false

  def lookup(key), do: :ets.lookup(:my_cache, key)
end

defmodule Argus.Test.Fixtures.EtsWriter do
  @moduledoc false

  def put(key, val), do: :ets.insert(:my_cache, {key, val})
end

defmodule Argus.Test.Fixtures.EtsUnnamed do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    table = :ets.new(:anon_table, [:set])
    {:ok, table}
  end
end

defmodule Argus.Test.Fixtures.EtsWellConfigured do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    table =
      :ets.new(:safe, [
        :set,
        :public,
        :named_table,
        {:heir, self(), nil},
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    {:ok, table}
  end
end

defmodule Argus.Test.Fixtures.EtsParamTable do
  @moduledoc false

  # Multi-clause function where the table reference comes from a parameter.
  # Clause 1 returns :ok (writing :ok to x0 before return), clause 2 uses
  # the parameter as an ETS table. Without barrier detection, the backward
  # resolver crosses the return boundary and picks up :ok as the table name.
  def lookup(:not_a_table), do: :ok
  def lookup(tab), do: :ets.lookup(tab, :key)

  def insert(:not_a_table, _record), do: :ok
  def insert(tab, record), do: :ets.insert(tab, record)
end

defmodule Argus.Test.Fixtures.EtsPermanentSupervisor do
  @moduledoc false
  use Supervisor

  # Supervises EtsOwner as a permanent child. The table will be
  # recreated on restart, so missing heir is not a real risk.
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Argus.Test.Fixtures.EtsOwner, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Fixtures.EtsApplicationOwner do
  @moduledoc false
  @behaviour Application

  # Application module that creates an ETS table. Lives for the entire
  # app lifetime — table loss is not a practical concern.
  @impl true
  def start(_type, _args) do
    :ets.new(:app_cache, [:set, :public, :named_table])
    Supervisor.start_link([], strategy: :one_for_one)
  end

  @impl true
  def stop(_state), do: :ok
end

defmodule Argus.Test.Fixtures.EtsAdminOps do
  @moduledoc false

  def delete_all(tab), do: :ets.delete_all_objects(tab)
  def delete_matching(tab), do: :ets.match_delete(tab, {:_, :stale})
  def give_away(tab, pid), do: :ets.give_away(tab, pid, :gift)
  def rename_table(tab, name), do: :ets.rename(tab, name)
  def set_opts(tab), do: :ets.setopts(tab, [{:heir, self(), nil}])
  def fix_table(tab), do: :ets.safe_fixtable(tab, true)
end

defmodule Argus.Test.Fixtures.ErlangStyleEtsSupervisor do
  @moduledoc false
  @behaviour :supervisor

  # Erlang-style supervisor returning {:ok, {flags, children}} directly.
  # Supervises EtsOwner as a permanent child.
  def start_link do
    :supervisor.start_link({:local, __MODULE__}, __MODULE__, [])
  end

  @impl true
  def init(_args) do
    {:ok,
     {%{strategy: :one_for_one, intensity: 5, period: 10},
      [
        %{
          id: Argus.Test.Fixtures.EtsOwner,
          start: {Argus.Test.Fixtures.EtsOwner, :start_link, [[]]},
          restart: :permanent,
          type: :worker
        }
      ]}}
  end
end

defmodule Argus.Test.Fixtures.EtsRefOps do
  @moduledoc false
  # Operations on a table REFERENCE (not a name atom) created in the
  # same function — the extractor should map the ref back to the
  # :ets.new site and attribute ops to :ref_table.

  def build do
    table = :ets.new(:ref_table, [:set])
    :ets.insert(table, {:a, 1})
    :ets.lookup(table, :a)
  end

  def build_across_call do
    table = :ets.new(:ref_table_two, [:set])
    seed = entropy()
    :ets.insert(table, {:seed, seed})
    table
  end

  defp entropy, do: :erlang.unique_integer()
end

defmodule Argus.Test.Fixtures.EtsGrowOnly do
  @moduledoc "The Sentry shape: a named table with inserts on the API and no deletes anywhere."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def record(id, value), do: :ets.insert(:audit_log, {id, value})

  @impl true
  def init(_) do
    :ets.new(:audit_log, [:named_table, :public, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsBounded do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def record(id, value), do: :ets.insert(:bounded_log, {id, value})
  def forget(id), do: :ets.delete(:bounded_log, id)

  @impl true
  def init(_) do
    :ets.new(:bounded_log, [:named_table, :public, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsSettings do
  @moduledoc """
  rabbit_disk_monitor's shape: a set table whose every insert names its
  key literally. Each overwrites the one row its key names; the table
  holds two rows however often the setters run.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def set_limit(n), do: :ets.insert(:settings_table, {:limit, n})
  def set_interval(ms), do: :ets.insert(:settings_table, {:interval, ms})

  @impl true
  def init(_) do
    :ets.new(:settings_table, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsSettingsBag do
  @moduledoc "The same literal keys into a bag: each insert adds a row. It only grows."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def set_limit(n), do: :ets.insert(:settings_bag, {:limit, n})

  @impl true
  def init(_) do
    :ets.new(:settings_bag, [:named_table, :protected, :bag])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsSettingsKeypos1 do
  @moduledoc "vernemq's cluster-state table: the default keypos spelled out, literal keys."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def set_limit(n), do: :ets.insert(:settings_keypos1, {:limit, n})

  @impl true
  def init(_) do
    :ets.new(:settings_keypos1, [:named_table, :protected, :set, {:keypos, 1}])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsSettingsKeypos2 do
  @moduledoc "Keyed on the second element: the literal first one says nothing. It only grows."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def record(id, n), do: :ets.insert(:settings_keypos2, {:limit, id, n})

  @impl true
  def init(_) do
    :ets.new(:settings_keypos2, [:named_table, :protected, :set, {:keypos, 2}])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsStrategy do
  @moduledoc """
  grpc's pick-first load balancer: a behaviour of its own, not a
  process's; init/1 runs in the caller and hands the table back.
  """
  @callback init(keyword()) :: {:ok, map()}

  def init(opts) do
    tid = :ets.new(:ets_strategy, [:set, :public])
    :ets.insert(tid, {:current, Keyword.get(opts, :first)})
    {:ok, %{tid: tid}}
  end
end

defmodule Argus.Test.Fixtures.EtsStrategyImpl do
  @moduledoc false
  @behaviour Argus.Test.Fixtures.EtsStrategy

  @impl true
  def init(opts) do
    tid = :ets.new(:ets_strategy_impl, [:set, :public])
    :ets.insert(tid, {:current, Keyword.get(opts, :first)})
    {:ok, %{tid: tid}}
  end
end

defmodule Argus.Test.Fixtures.EtsWarmCache do
  @moduledoc "Filled once in init/1, read forever: a cache, not a leak."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def fetch(key), do: :ets.lookup(:warm_cache, key)

  @impl true
  def init(entries) do
    :ets.new(:warm_cache, [:named_table, :protected, :set])
    :ets.insert(:warm_cache, entries)
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsSharedCounters do
  @moduledoc """
  A named ordered_set, created with no concurrency options, that two
  modules read and two modules write.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def read(key), do: :ets.lookup(:shared_counters, key)
  def write(key, n), do: :ets.insert(:shared_counters, {key, n})

  @impl true
  def init(_) do
    :ets.new(:shared_counters, [:ordered_set, :public, :named_table])
    {:ok, nil}
  end
end

defmodule Argus.Test.Fixtures.EtsSharedCountersClient do
  @moduledoc false
  def read(key), do: :ets.lookup(:shared_counters, key)
  def write(key, n), do: :ets.insert(:shared_counters, {key, n})
end

defmodule Argus.Test.Fixtures.EtsSharedTuned do
  @moduledoc "The same sharing, with both options set and a set table: nothing to hint."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def read(key), do: :ets.lookup(:shared_tuned, key)
  def write(key, n), do: :ets.insert(:shared_tuned, {key, n})

  @impl true
  def init(_) do
    :ets.new(:shared_tuned, [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, nil}
  end
end

defmodule Argus.Test.Fixtures.EtsSharedTunedClient do
  @moduledoc false
  def read(key), do: :ets.lookup(:shared_tuned, key)
  def write(key, n), do: :ets.insert(:shared_tuned, {key, n})
end

defmodule Argus.Test.Fixtures.EtsTableHelper do
  @moduledoc "Creates tables on the stack of whichever process calls it."

  def create, do: :ets.new(:helper_made, [:set, :public, :named_table])
  def create_unnamed, do: :ets.new(:helper_unnamed, [:set])
end

defmodule Argus.Test.Fixtures.EtsHelperOwner do
  @moduledoc """
  Its init/1 has a helper module create its tables: they are its
  process's, and go when it does. The named one is shared state the
  helper sets up for it; the unnamed one is a value the helper hands
  back, held as its state is.
  """
  use GenServer

  alias Argus.Test.Fixtures.EtsTableHelper

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    EtsTableHelper.create()
    {:ok, EtsTableHelper.create_unnamed()}
  end
end

defmodule Argus.Test.Fixtures.EtsClientCreated do
  @moduledoc """
  A server module whose client function creates a table: the table is
  its caller's, not the server's.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def ensure_table, do: :ets.new(:client_made, [:set, :public, :named_table])
  def ensure_unnamed, do: :ets.new(:client_unnamed, [:set])

  @impl true
  def init(_), do: {:ok, %{}}
end

defmodule Argus.Test.Fixtures.EtsSecondHelperOwner do
  @moduledoc "A second server whose init/1 may make the helper's named table first."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    Argus.Test.Fixtures.EtsTableHelper.create()
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsPrivateOwner do
  @moduledoc """
  A private table: no other process can read it, so none meets it gone;
  its rows are the owner's state, lost with it as its heap is.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    table = :ets.new(:private_dedup, [:set, :private])
    {:ok, table}
  end
end

# Adversarial probes for the private-table excuse (FP hunt round 3): each
# keeps a table another process can read, or one whose access the
# bytecode does not show.

defmodule Argus.Test.Fixtures.EtsProtectedOwner do
  @moduledoc "A named table with the default access, protected: every process reads it."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    table = :ets.new(:protected_cache, [:set, :named_table])
    {:ok, table}
  end
end

defmodule Argus.Test.Fixtures.EtsOptionsFromArgOwner do
  @moduledoc "A named table whose options come from its caller: its access is not shown."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    table = :ets.new(:configured_cache, [:named_table | opts])
    {:ok, table}
  end
end

defmodule Argus.Test.Fixtures.EtsPrivateAndPublicOwner do
  @moduledoc "A private table beside a public named one: the public one is still reported."
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_) do
    private = :ets.new(:owner_scratch, [:set, :private])
    :ets.new(:owner_shared, [:set, :public, :named_table])
    {:ok, private}
  end
end
