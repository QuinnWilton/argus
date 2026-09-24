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

  # ── Across functions ─────────────────────────────────────────────

  defmodule HelperAct do
    @moduledoc "The count sits in a helper the found-row branch calls."
    @table :helper_act_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          bump(key)
      end
    end

    defp bump(key), do: :ets.update_counter(@table, key, {2, 1})

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule HelperCheck do
    @moduledoc "The check sits in a helper that returns whether the row is there."
    @table :helper_check_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      if exists?(key) do
        :ets.update_counter(@table, key, {2, 1})
      else
        :ets.insert(@table, {key, 0})
        _ = :timer.apply_after(10, __MODULE__, :flush, [key])
        :ok
      end
    end

    defp exists?(key), do: :ets.member(@table, key)

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule CrossModuleAct do
    @moduledoc "The count is another module's function."
    @table :cross_module_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      case :ets.lookup(@table, key) do
        [] -> :ets.insert(@table, {key, 0})
        [_existing] -> Argus.Test.Fixtures.MissingRow.Counter.bump(key)
      end
    end

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule Counter do
    @moduledoc "CrossModuleAct's count."
    def bump(key), do: :ets.update_counter(:cross_module_buckets, key, {2, 1})
  end

  # ── Where the miss is rescued ────────────────────────────────────

  defmodule UnrelatedRescue do
    @moduledoc "A rescue around unrelated code after the count: the count's miss still raises."
    @table :unrelated_rescue_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key, payload) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          :ets.update_counter(@table, key, {2, 1})
      end

      try do
        :erlang.binary_to_term(payload)
      rescue
        _ -> :bad
      end
    end

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule HelperRescue do
    @moduledoc "The helper that counts rescues its own miss."
    @table :helper_rescue_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          safe_bump(key)
      end
    end

    defp safe_bump(key) do
      :ets.update_counter(@table, key, {2, 1})
    rescue
      ArgumentError -> 0
    end

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule CallerRescues do
    @moduledoc "The one caller of the private function that counts rescues the miss around the call."
    @table :caller_rescue_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      do_log(key)
    rescue
      ArgumentError -> :ok
    end

    defp do_log(key) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          :ets.update_counter(@table, key, {2, 1})
      end
    end

    def flush(key), do: :ets.take(@table, key)
  end

  defmodule OneCallerRescues do
    @moduledoc "One caller rescues around the call and the other does not."
    @table :one_caller_rescue_buckets

    def setup, do: :ets.new(@table, [:set, :named_table, :public])

    def log(key) do
      do_log(key)
    rescue
      ArgumentError -> :ok
    end

    def log_unguarded(key), do: do_log(key)

    defp do_log(key) do
      case :ets.lookup(@table, key) do
        [] ->
          :ets.insert(@table, {key, 0})
          _ = :timer.apply_after(10, __MODULE__, :flush, [key])
          :ok

        [_existing] ->
          :ets.update_counter(@table, key, {2, 1})
      end
    end

    def flush(key), do: :ets.take(@table, key)
  end
end
