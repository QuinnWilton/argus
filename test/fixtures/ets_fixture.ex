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
