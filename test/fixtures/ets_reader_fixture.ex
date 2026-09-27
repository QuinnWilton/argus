defmodule Argus.Test.Fixtures.EtsOwners do
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

  defmodule WhereisOwner do
    @moduledoc false
    # hackney's HTTP/3 table, Sentry's dedupe: the reader asks whether the
    # table is there before reading it.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key) do
      case :ets.whereis(:ets_reader_whereis) do
        :undefined -> []
        _ -> :ets.lookup(:ets_reader_whereis, key)
      end
    end

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_whereis, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule WhereisElsewhereOwner do
    @moduledoc false
    # The question asked in one function, the read made in another: a
    # caller that reads without asking is not guarded by it.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def ready?, do: :ets.whereis(:ets_reader_whereis_elsewhere) != :undefined

    def lookup(key), do: :ets.lookup(:ets_reader_whereis_elsewhere, key)

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_whereis_elsewhere, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule InfoOwner do
    @moduledoc false
    # :ets.info answers :undefined for a table that is gone: no raise.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def count, do: :ets.info(:ets_reader_info, :size)

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_info, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule BadargOwner do
    @moduledoc false
    # postgrex's soft_read: `catch :error, :badarg` takes the missing table.
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key) do
      :ets.lookup_element(:ets_reader_badarg, key, 2)
    catch
      :error, :badarg -> nil
    end

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_badarg, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule DynamicOwnerNamedRead do
    @moduledoc false
    # The owner's table has a computed name; its API reads another,
    # named table. That read is not of the owner's table.
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name)

    def settings(key), do: :ets.lookup(:some_settings, key)

    @impl true
    def init(name) do
      :ets.new(name, [:protected, :set])
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

  defmodule UnrelatedRescueOwner do
    @moduledoc """
    A rescue in the reader, around code after the read: it takes nothing
    the read raises.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    def lookup(key) do
      rows = :ets.lookup(:ets_reader_unrelated, key)

      try do
        Enum.map(rows, &elem(&1, 1))
      rescue
        ArgumentError -> []
      end
    end

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_unrelated, [:named_table, :protected, :set])
      {:ok, %{}}
    end
  end

  defmodule SpawnedReader do
    @moduledoc """
    The owner's callback starts an unlinked task that reads the table: the
    task outlives the owner's crash, and reads while the table is gone.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      :ets.new(:ets_reader_spawned, [:named_table, :protected, :set])
      {:ok, %{}}
    end

    @impl true
    def handle_cast({:report, key}, state) do
      Task.start(fn -> IO.inspect(:ets.lookup(:ets_reader_spawned, key)) end)
      {:noreply, state}
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

defmodule Argus.Test.Fixtures.EtsOwners.Helper do
  @moduledoc false
  # The table arrives as a parameter; the caller's literal names it.
  def fetch(table, key), do: :ets.lookup(table, key)
end

defmodule Argus.Test.Fixtures.EtsOwners.HelperOwner do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(key), do: Argus.Test.Fixtures.EtsOwners.Helper.fetch(:ets_reader_helper, key)

  @impl true
  def init(_opts) do
    :ets.new(:ets_reader_helper, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsOwners.HelperUnrelatedRescueOwner do
  @moduledoc false
  # The caller's literal names the table; its rescue covers other code.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(key) do
    rows = Argus.Test.Fixtures.EtsOwners.Helper.fetch(:ets_reader_helper_unrelated, key)

    try do
      Enum.map(rows, &elem(&1, 1))
    rescue
      ArgumentError -> []
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(:ets_reader_helper_unrelated, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsOwners.HelperGuardedOwner do
  @moduledoc false
  # The caller's literal names the table, and a rescue covers the call.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(key) do
    Argus.Test.Fixtures.EtsOwners.Helper.fetch(:ets_reader_helper_guarded, key)
  rescue
    ArgumentError -> []
  end

  @impl true
  def init(_opts) do
    :ets.new(:ets_reader_helper_guarded, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsOwners.CallerRescuedOwner do
  @moduledoc false
  # The read is in a private function whose one caller rescues it.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(key) do
    read(key)
  rescue
    ArgumentError -> []
  end

  defp read(key), do: :ets.lookup(:ets_reader_caller_rescued, key)

  @impl true
  def init(_opts) do
    :ets.new(:ets_reader_caller_rescued, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end

defmodule Argus.Test.Fixtures.EtsOwners.WrongRescueOwner do
  @moduledoc false
  # A rescue of another exception around the read takes nothing of it.
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def lookup(key) do
    :ets.lookup(:ets_reader_wrong_rescue, key)
  rescue
    KeyError -> []
  end

  @impl true
  def init(_opts) do
    :ets.new(:ets_reader_wrong_rescue, [:named_table, :protected, :set])
    {:ok, %{}}
  end
end
