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
