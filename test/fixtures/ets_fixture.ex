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
