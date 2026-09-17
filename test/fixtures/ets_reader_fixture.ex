defmodule Argus.Test.Fixtures.EtsReader do
  @moduledoc false

  defmodule Owner do
    @moduledoc false
    # redix#338: the API reads a table that vanishes while its owner restarts.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key), do: :ets.lookup(:ets_reader_owner, key)

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_owner, [:named_table, :protected, :set])
      {:ok, %{}}
    end

    @impl true
    def handle_call({:put, key, value}, _from, state) do
      :ets.insert(:ets_reader_owner, {key, value})
      {:reply, :ok, state}
    end
  end

  defmodule GuardedOwner do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key) do
      :ets.lookup(:ets_reader_guarded, key)
    rescue
      ArgumentError -> []
    end

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_guarded, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule ClosureGuardedOwner do
    @moduledoc false
    # The read sits in a closure handed to a rescuing wrapper (redix's fix).
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key), do: guard(fn -> :ets.lookup(:ets_reader_closure, key) end, [])

    def guard(fun, default) do
      fun.()
    rescue
      ArgumentError -> default
    end

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_closure, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule HeirOwner do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key), do: :ets.lookup(:ets_reader_heir, key)

    @impl true
    def init(heir) do
      :ets.new(:ets_reader_heir, [:named_table, :protected, :set, {:heir, heir, nil}])
      {:ok, %{}}
    end
  end

  defmodule InsideOwner do
    @moduledoc false
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key), do: GenServer.call(__MODULE__, {:lookup, key})

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_inside, [:named_table, :protected, :set])
      {:ok, %{}}
    end

    @impl true
    def handle_call({:lookup, key}, _from, state) do
      {:reply, :ets.lookup(:ets_reader_inside, key), state}
    end
  end
end
