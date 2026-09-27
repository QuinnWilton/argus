defmodule Argus.Test.Fixtures.Dictionary do
  @moduledoc """
  Fixtures for values kept in the process dictionary: a key put and read
  back in one process names the same value (processes.dl's `dict`
  source), a key another process put names nothing, and a table named
  only while a key is unset is set aside where the key was set first
  (clientlib/dictionary.dl).
  """

  # ── A table named while a key is unset ──────────────────────────────

  defmodule TmpOptions do
    @moduledoc """
    ejabberd_config's temporary options: validate/1 makes a private table
    and puts it under the key the options table is named by, and every
    option operation names the table the key holds, or the options table
    when it holds none. From validate/1 the read and the write touch the
    private table; from reload/1, which sets nothing, the public options
    table, where another process can write the row between the two; from
    abort/1, which erases the key again first, the public table too.
    """
    def start, do: :ets.new(:dict_options, [:named_table, :public])

    def validate(hosts) do
      create_tmp()
      set_option(:hosts, get_option(:hosts) ++ hosts)
    end

    def reload(hosts), do: set_option(:hosts, get_option(:hosts) ++ hosts)

    def abort(hosts) do
      create_tmp()
      delete_tmp()
      set_option(:hosts, get_option(:hosts) ++ hosts)
    end

    def get_option(key) do
      tab =
        case get_tmp() do
          nil -> :dict_options
          t -> t
        end

      case :ets.lookup(tab, key) do
        [{^key, value}] -> value
        [] -> []
      end
    end

    def set_option(key, value) do
      tab =
        case get_tmp() do
          nil -> :dict_options
          t -> t
        end

      :ets.insert(tab, {key, value})
    end

    defp create_tmp, do: Process.put(:dict_options, :ets.new(:tmp_options, [:private]))

    defp get_tmp, do: Process.get(:dict_options)

    defp delete_tmp do
      case get_tmp() do
        nil ->
          :ok

        t ->
          Process.delete(:dict_options)
          :ets.delete(t)
      end
    end
  end

  defmodule OrDefault do
    @moduledoc """
    The `||` spelling of a default, over a read in place; a default over a
    parameter is no key's.
    """
    def put(key, value), do: :ets.insert(Process.get(:or_default) || :or_default, {key, value})

    def put_into(tab, key, value), do: :ets.insert(tab || :or_default, {key, value})
  end

  # ── Which process put the key ───────────────────────────────────────

  defmodule CallerTable do
    @moduledoc """
    Each calling process makes a counter table of its own the first time
    it counts, and keeps it in its dictionary: the read and the write
    are on a table no other process holds.
    """
    def bump(key) do
      tab = table()

      case :ets.lookup(tab, key) do
        [] -> :ets.insert(tab, {key, 1})
        [{^key, n}] -> :ets.insert(tab, {key, n + 1})
      end
    end

    defp table do
      case Process.get(:caller_table) do
        nil ->
          t = :ets.new(:caller_table, [:public])
          Process.put(:caller_table, t)
          t

        t ->
          t
      end
    end
  end

  defmodule SharedCallerTable do
    @moduledoc """
    CallerTable, whose table is also handed to a registry process: the
    table leaves its maker, and another process holding it can write the
    row between the read and the write.
    """
    def bump(key, registry) do
      tab = table(registry)

      case :ets.lookup(tab, key) do
        [] -> :ets.insert(tab, {key, 1})
        [{^key, n}] -> :ets.insert(tab, {key, n + 1})
      end
    end

    defp table(registry) do
      case Process.get(:shared_caller_table) do
        nil ->
          t = :ets.new(:shared_caller_table, [:public])
          Process.put(:shared_caller_table, t)
          send(registry, {:table, t})
          t

        t ->
          t
      end
    end
  end

  defmodule OwnTable do
    @moduledoc """
    A server keeps a table it makes in init/1 in its dictionary, and its
    handle_call/3 reads it back: the same process, the same table.
    """
    @behaviour GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      Process.put(:own_table, :ets.new(:own_table, [:public]))
      {:ok, nil}
    end

    @impl true
    def handle_call({:count, key}, _from, state) do
      {:reply, :ets.update_counter(table(), key, 1, {key, 0}), state}
    end

    defp table, do: Process.get(:own_table)
  end

  defmodule OtherProcess do
    @moduledoc """
    A server keeps a table under a key, and an API function its callers
    run in their own processes reads the key: their dictionaries hold
    nothing under it, and the read names no table.
    """
    @behaviour GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, :ok)

    @impl true
    def init(:ok) do
      Process.put(:other_table, :ets.new(:other_table, [:public]))
      {:ok, nil}
    end

    def count(key), do: :ets.update_counter(Process.get(:other_table), key, 1, {key, 0})
  end

  defmodule ComputedKey do
    @moduledoc """
    A table kept under a key computed at run time is not followed; the
    same table under a literal key is.
    """
    def run(id, key) do
      Process.put({:computed, id}, :ets.new(:computed, [:public]))
      :ets.insert(Process.get({:computed, id}), {key, 1})
    end

    def run_literal(key) do
      Process.put({:computed, :fixed}, :ets.new(:computed_fixed, [:public]))
      :ets.insert(Process.get({:computed, :fixed}), {key, 1})
    end
  end
end
