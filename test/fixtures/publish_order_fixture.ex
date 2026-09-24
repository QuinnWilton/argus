defmodule Argus.Test.Fixtures.PublishOrder do
  @moduledoc """
  Fixtures for `races.ets_publish_order`: a value written into one ETS
  table before the row another table keys by it, read by a process that
  raises on the missing row. The positives are plain modules — an API
  every caller's process runs; the quiet neighbours write in the safe
  order, read with a default, rescue the raise, or keep the tables where
  no other process sees them.
  """

  defmodule MapFields do
    @moduledoc """
    Two unnamed public tables handed around in one map, created with one
    name: only the fields tell them apart. The shape `Argus.Symbols.ETS`
    had.
    """
    def new do
      %{
        forward: :ets.new(:symbols, [:set, :public]),
        reverse: :ets.new(:symbols, [:set, :public]),
        counter: :atomics.new(1, signed: false)
      }
    end

    def intern(%{forward: forward, reverse: reverse, counter: counter}, binary) do
      case :ets.lookup(forward, binary) do
        [{_, id}] ->
          id

        [] ->
          id = :atomics.add_get(counter, 1, 1)

          if :ets.insert_new(forward, {binary, id}) do
            true = :ets.insert(reverse, {id, binary})
            id
          else
            [{_, winner}] = :ets.lookup(forward, binary)
            winner
          end
      end
    end

    def resolve(%{reverse: reverse}, id), do: :ets.lookup_element(reverse, id, 2)
  end

  defmodule ReverseFirst do
    @moduledoc "The same tables, written in the safe order: the row first, then the value."
    def new do
      %{
        forward: :ets.new(:symbols, [:set, :public]),
        reverse: :ets.new(:symbols, [:set, :public]),
        counter: :atomics.new(1, signed: false)
      }
    end

    def intern(%{forward: forward, reverse: reverse, counter: counter}, binary) do
      case :ets.lookup(forward, binary) do
        [{_, id}] ->
          id

        [] ->
          id = :atomics.add_get(counter, 1, 1)
          true = :ets.insert(reverse, {id, binary})

          if :ets.insert_new(forward, {binary, id}) do
            id
          else
            :ets.delete(reverse, id)
            [{_, winner}] = :ets.lookup(forward, binary)
            winner
          end
      end
    end

    def resolve(%{reverse: reverse}, id), do: :ets.lookup_element(reverse, id, 2)
  end

  defmodule NamedTables do
    @moduledoc "Two named public tables, the id handed out by a lookup of the first."
    def setup do
      :ets.new(:users_by_name, [:named_table, :public, :set])
      :ets.new(:users_by_id, [:named_table, :public, :set])
    end

    def register(name, id) do
      :ets.insert(:users_by_name, {name, id})
      :ets.insert(:users_by_id, {id, name})
    end

    def id_of(name) do
      case :ets.lookup(:users_by_name, name) do
        [{_, id}] -> id
        [] -> nil
      end
    end

    def name_of(id), do: :ets.lookup_element(:users_by_id, id, 2)
  end

  defmodule CountedById do
    @moduledoc "The second table is counted into by id: update_counter/3 raises on the missing row."
    def setup do
      :ets.new(:sessions, [:named_table, :public, :set])
      :ets.new(:session_hits, [:named_table, :public, :set])
    end

    def open(token, id) do
      :ets.insert(:sessions, {token, id})
      :ets.insert(:session_hits, {id, 0})
    end

    def session(token), do: :ets.lookup(:sessions, token)

    def hit(id), do: :ets.update_counter(:session_hits, id, 1)
  end

  defmodule DefaultedReader do
    @moduledoc "The same order, but the reader takes a default: a miss is an answer."
    def setup do
      :ets.new(:paths_by_name, [:named_table, :public, :set])
      :ets.new(:paths_by_id, [:named_table, :public, :set])
    end

    def register(name, id) do
      :ets.insert(:paths_by_name, {name, id})
      :ets.insert(:paths_by_id, {id, name})
    end

    def id_of(name), do: :ets.lookup(:paths_by_name, name)

    def name_of(id), do: :ets.lookup_element(:paths_by_id, id, 2, nil)
  end

  defmodule RescuedReader do
    @moduledoc "The same order, and the raising reader rescues the miss."
    def setup do
      :ets.new(:hosts_by_name, [:named_table, :public, :set])
      :ets.new(:hosts_by_id, [:named_table, :public, :set])
    end

    def register(name, id) do
      :ets.insert(:hosts_by_name, {name, id})
      :ets.insert(:hosts_by_id, {id, name})
    end

    def id_of(name), do: :ets.lookup(:hosts_by_name, name)

    def name_of(id) do
      :ets.lookup_element(:hosts_by_id, id, 2)
    rescue
      ArgumentError -> nil
    end
  end

  defmodule PrivateTables do
    @moduledoc "The same order on private tables: no other process can read either."
    def setup do
      :ets.new(:keys_by_name, [:named_table, :private, :set])
      :ets.new(:keys_by_id, [:named_table, :private, :set])
    end

    def register(name, id) do
      :ets.insert(:keys_by_name, {name, id})
      :ets.insert(:keys_by_id, {id, name})
    end

    def id_of(name), do: :ets.lookup(:keys_by_name, name)

    def name_of(id), do: :ets.lookup_element(:keys_by_id, id, 2)
  end

  defmodule OwnerOnly do
    @moduledoc """
    The same order on protected tables whose owner is the only process
    that writes or reads them: its callbacks run one at a time.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:tags_by_name, [:named_table, :protected, :set])
      :ets.new(:tags_by_id, [:named_table, :protected, :set])
      {:ok, state}
    end

    @impl true
    def handle_call({:register, name, id}, _from, state) do
      :ets.insert(:tags_by_name, {name, id})
      :ets.insert(:tags_by_id, {id, name})
      {:reply, :ok, state}
    end

    def handle_call({:name_of, name}, _from, state) do
      [{_, id}] = :ets.lookup(:tags_by_name, name)
      {:reply, :ets.lookup_element(:tags_by_id, id, 2), state}
    end
  end

  defmodule SameKey do
    @moduledoc "Both tables keyed by the same thing: nothing is read out of one to find the other."
    def setup do
      :ets.new(:meta, [:named_table, :public, :set])
      :ets.new(:data, [:named_table, :public, :set])
    end

    def put(key, meta, data) do
      :ets.insert(:meta, {key, meta})
      :ets.insert(:data, {key, data})
    end

    def meta(key), do: :ets.lookup(:meta, key)

    def data(key), do: :ets.lookup_element(:data, key, 2)
  end
end
