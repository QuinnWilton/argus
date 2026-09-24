defmodule Argus.Test.Fixtures.MissingRow do
  @moduledoc """
  Fixtures for `races.ets_missing_row`: a read decides a row is there, an
  operation that raises when it is not acts on it, and another process
  can take the row between the two. The positive is sequin's
  DebouncedLogger in miniature; the quiet neighbours act with a default,
  rescue the miss, or keep every touch of the table in one process.
  """

  defmodule Debounce do
    @moduledoc "Counts repeats of a key; a timer's flush, in a process of its own, takes the row."
    @default_table :debounce_buckets

    defmodule Config do
      @moduledoc false
      defstruct [:key, table_name: nil, interval: 10]
    end

    def setup(table \\ @default_table) do
      :ets.new(table, [:set, :named_table, :public])
    end

    def log(%Config{} = cfg) do
      table = cfg.table_name || @default_table

      case :ets.lookup(table, cfg.key) do
        [] ->
          :ets.insert(table, {cfg.key, 0})
          _ = :timer.apply_after(cfg.interval, __MODULE__, :flush, [table, cfg.key])
          :ok

        [_existing] ->
          :ets.update_counter(table, cfg.key, {2, 1})
          :ok
      end
    end

    def flush(table \\ @default_table, key) do
      case :ets.take(table, key) do
        [{^key, count}] when count > 0 -> {:repeated, count}
        _ -> :ok
      end
    end
  end

  defmodule WithDefault do
    @moduledoc "The same shape, counting with a default object: a missing row is created, not raised on."
    @table :debounce_defaulted

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          :ets.update_counter(@table, key, {2, 1}, {key, 0})
          :ok
      end
    end

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule Rescued do
    @moduledoc "The same shape, with the miss rescued."
    @table :debounce_rescued

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          :ets.update_counter(@table, key, {2, 1})
          :ok
      end
    rescue
      ArgumentError -> :ok
    end

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule OneOwner do
    @moduledoc "A server that counts and flushes in its own callbacks: one process touches the table."
    use GenServer

    @table :debounce_owned

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(@table, [:set, :named_table, :protected])
      {:ok, state}
    end

    @impl true
    def handle_cast({:log, key}, state) do
      case :ets.lookup(@table, key) do
        [] -> :ets.insert(@table, {key, 0})
        [_existing] -> :ets.update_counter(@table, key, {2, 1})
      end

      {:noreply, state}
    end

    @impl true
    def handle_info({:flush, key}, state) do
      :ets.take(@table, key)
      {:noreply, state}
    end
  end
end
