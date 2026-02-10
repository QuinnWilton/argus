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
