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
    name: only the fields tell them apart. The shape argus's interned
    symbol table had, before 0.20.
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

  defmodule UnrelatedRescueReader do
    @moduledoc "The same order; the raising reader rescues only other code after the read."
    def setup do
      :ets.new(:peers_by_name, [:named_table, :public, :set])
      :ets.new(:peers_by_id, [:named_table, :public, :set])
    end

    def register(name, id) do
      :ets.insert(:peers_by_name, {name, id})
      :ets.insert(:peers_by_id, {id, name})
    end

    def id_of(name), do: :ets.lookup(:peers_by_name, name)

    def name_of(id, payload) do
      name = :ets.lookup_element(:peers_by_id, id, 2)

      try do
        {name, :erlang.binary_to_term(payload)}
      rescue
        _ -> {name, nil}
      end
    end
  end

  defmodule WrongRescueReader do
    @moduledoc "The same order; the raising reader rescues another exception."
    def setup do
      :ets.new(:nodes_by_name, [:named_table, :public, :set])
      :ets.new(:nodes_by_id, [:named_table, :public, :set])
    end

    def register(name, id) do
      :ets.insert(:nodes_by_name, {name, id})
      :ets.insert(:nodes_by_id, {id, name})
    end

    def id_of(name), do: :ets.lookup(:nodes_by_name, name)

    def name_of(id) do
      :ets.lookup_element(:nodes_by_id, id, 2)
    rescue
      KeyError -> nil
    end
  end

  defmodule CallerRescuesReader do
    @moduledoc "The same order; the raising reader is private and its one caller rescues the miss."
    def setup do
      :ets.new(:links_by_name, [:named_table, :public, :set])
      :ets.new(:links_by_id, [:named_table, :public, :set])
    end

    def register(name, id) do
      :ets.insert(:links_by_name, {name, id})
      :ets.insert(:links_by_id, {id, name})
    end

    def id_of(name), do: :ets.lookup(:links_by_name, name)

    def name_of(id) do
      lookup_name(id)
    rescue
      ArgumentError -> nil
    end

    defp lookup_name(id), do: :ets.lookup_element(:links_by_id, id, 2)
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

  # ── Tables known by where they were made ──────────────────────────

  defmodule LocalPair do
    @moduledoc """
    Two unnamed tables that live in a tuple, never in a map field or under
    a name: only the `:ets.new/2` calls that made them tell them apart,
    followed to their operations as a pid is.
    """
    def new, do: {:ets.new(:names, [:set, :public]), :ets.new(:ids, [:set, :public])}

    def register({names, ids}, name) do
      id = System.unique_integer([:positive])
      :ets.insert(names, {name, id})
      :ets.insert(ids, {id, name})
      id
    end

    def id_of({names, _ids}, name) do
      [{_, id}] = :ets.lookup(names, name)
      id
    end

    def name_of({_names, ids}, id), do: :ets.lookup_element(ids, id, 2)

    def demo do
      tables = new()
      register(tables, "a")
      name_of(tables, id_of(tables, "a"))
    end
  end

  defmodule LocalPairSafe do
    @moduledoc "The same tuple of tables, written row first."
    def new, do: {:ets.new(:names, [:set, :public]), :ets.new(:ids, [:set, :public])}

    def register({names, ids}, name) do
      id = System.unique_integer([:positive])
      :ets.insert(ids, {id, name})
      :ets.insert(names, {name, id})
      id
    end

    def id_of({names, _ids}, name) do
      [{_, id}] = :ets.lookup(names, name)
      id
    end

    def name_of({_names, ids}, id), do: :ets.lookup_element(ids, id, 2)

    def demo do
      tables = new()
      register(tables, "a")
      name_of(tables, id_of(tables, "a"))
    end
  end

  defmodule SameFieldTwoMaps do
    @moduledoc """
    Two maps that keep different tables under one field name, `:t`. By
    field alone they are one table and nothing is published; by where each
    was made they are two.
    """
    def new, do: {%{t: :ets.new(:names, [:set, :public])}, %{t: :ets.new(:ids, [:set, :public])}}

    def register(%{t: names}, %{t: ids}, name) do
      id = System.unique_integer([:positive])
      :ets.insert(names, {name, id})
      :ets.insert(ids, {id, name})
      id
    end

    def id_of(%{t: names}, name) do
      [{_, id}] = :ets.lookup(names, name)
      id
    end

    def name_of(%{t: ids}, id), do: :ets.lookup_element(ids, id, 2)

    def demo do
      {names, ids} = new()
      register(names, ids, "a")
      name_of(ids, id_of(names, "a"))
    end
  end

  # ── Writes split across a call ────────────────────────────────────

  defmodule HelperCompletes do
    @moduledoc "The value is published here; the row it points to is written by a helper, after."
    def setup do
      :ets.new(:people_by_name, [:named_table, :public, :set])
      :ets.new(:people_by_id, [:named_table, :public, :set])
    end

    def add(name) do
      id = System.unique_integer([:positive])
      :ets.insert(:people_by_name, {name, id})
      index(id, name)
    end

    defp index(id, name), do: :ets.insert(:people_by_id, {id, name})

    def name_of(name) do
      [{_, id}] = :ets.lookup(:people_by_name, name)
      :ets.lookup_element(:people_by_id, id, 2)
    end
  end

  defmodule HelperFirst do
    @moduledoc "The helper writes the row before the value is published."
    def setup do
      :ets.new(:pets_by_name, [:named_table, :public, :set])
      :ets.new(:pets_by_id, [:named_table, :public, :set])
    end

    def add(name) do
      id = System.unique_integer([:positive])
      index(id, name)
      :ets.insert(:pets_by_name, {name, id})
    end

    defp index(id, name), do: :ets.insert(:pets_by_id, {id, name})

    def name_of(name) do
      [{_, id}] = :ets.lookup(:pets_by_name, name)
      :ets.lookup_element(:pets_by_id, id, 2)
    end
  end

  # ── Where the reader's key comes from ─────────────────────────────

  defmodule KeyFromElsewhere do
    @moduledoc """
    The raising reader only ever reads the second table at a key taken
    from a third table, never at an id handed out by the first.
    """
    def setup do
      :ets.new(:cars_by_name, [:named_table, :public, :set])
      :ets.new(:cars_by_id, [:named_table, :public, :set])
      :ets.new(:current_car, [:named_table, :public, :set])
    end

    def add(name) do
      id = System.unique_integer([:positive])
      :ets.insert(:cars_by_name, {name, id})
      :ets.insert(:cars_by_id, {id, name})
      id
    end

    def id_of(name) do
      [{_, id}] = :ets.lookup(:cars_by_name, name)
      id
    end

    def current, do: name_at(current_id())

    defp current_id do
      [{:current, id}] = :ets.lookup(:current_car, :current)
      id
    end

    defp name_at(id), do: :ets.lookup_element(:cars_by_id, id, 2)
  end

  defmodule KeyFromFirst do
    @moduledoc "The same private reader, handed an id read out of the first table."
    def setup do
      :ets.new(:boats_by_name, [:named_table, :public, :set])
      :ets.new(:boats_by_id, [:named_table, :public, :set])
    end

    def add(name) do
      id = System.unique_integer([:positive])
      :ets.insert(:boats_by_name, {name, id})
      :ets.insert(:boats_by_id, {id, name})
      id
    end

    def rename(name), do: name_at(id_of(name))

    defp id_of(name) do
      [{_, id}] = :ets.lookup(:boats_by_name, name)
      id
    end

    defp name_at(id), do: :ets.lookup_element(:boats_by_id, id, 2)
  end
end
