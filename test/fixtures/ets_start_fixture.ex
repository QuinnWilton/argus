defmodule Argus.Test.Fixtures.EtsStart do
  @moduledoc """
  Fixtures for `ets.ets_created_in_start`: a server's `start_link` runs in
  the process that starts it, so a named table it creates belongs to the
  supervisor, and the restart's `:ets.new/2` raises on the taken name.
  Each quiet shape differs from a positive in one premise: the table is
  made in init/1, the start function asks first, rescues the second
  create, gives the table away, makes an unnamed table, or belongs to a
  temporary child; a plain module's `start_link` starts no server.
  """

  defmodule InStart do
    @moduledoc "ex_uid2's Dsp: start_link creates the table the server writes."
    use GenServer

    @table :in_start_keys

    def start_link(opts) do
      :ets.new(@table, [:named_table, {:read_concurrency, true}, :public])
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info(:refresh, state) do
      :ets.insert(@table, {:keys, []})
      {:noreply, state}
    end
  end

  defmodule InHelper do
    @moduledoc "The same, through a helper start_link calls."
    use GenServer

    def start_link(opts) do
      create_table()
      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    defp create_table, do: :ets.new(:in_helper_cache, [:named_table, :public])

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule InSupervisorStart do
    @moduledoc "A supervisor's own start_link runs in its parent: the same defect one level up."
    use Supervisor

    def start_link(opts) do
      :ets.new(:in_supervisor_start, [:named_table, :public])
      Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
  end

  defmodule InInit do
    @moduledoc "The fix: init/1 creates it, in the server's own process. Quiet."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      :ets.new(:in_init_keys, [:named_table, {:read_concurrency, true}, :public])
      {:ok, opts}
    end
  end

  defmodule AsksFirst do
    @moduledoc "start_link creates the table only when :ets.whereis/1 does not find it. Quiet."
    use GenServer

    @table :asks_first_bot_info

    def start_link(opts) do
      if :ets.whereis(@table) == :undefined do
        :ets.new(@table, [:set, :named_table, :public])
      end

      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule Rescues do
    @moduledoc "start_link rescues the ArgumentError a second create raises. Quiet."
    use GenServer

    def start_link(opts) do
      try do
        :ets.new(:rescues_cache, [:named_table, :public])
      rescue
        ArgumentError -> :rescues_cache
      end

      GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule GivesAway do
    @moduledoc "start_link hands the table to the server it started, which then owns it. Quiet."
    use GenServer

    def start_link(opts) do
      table = :ets.new(:gives_away_cache, [:named_table, :public])
      {:ok, pid} = GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      true = :ets.give_away(table, pid, :table)
      {:ok, pid}
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info({:"ETS-TRANSFER", _table, _from, :table}, state), do: {:noreply, state}
  end

  defmodule Unnamed do
    @moduledoc "An unnamed table: a second one does not collide. Quiet (for this rule)."
    use GenServer

    def start_link(opts) do
      table = :ets.new(:unnamed_cache, [:public])
      GenServer.start_link(__MODULE__, {table, opts})
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  defmodule Temporary do
    @moduledoc "A temporary child is never restarted. Quiet."
    use GenServer, restart: :temporary

    def start_link(opts) do
      :ets.new(:temporary_cache, [:named_table, :public])
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule NotAServer do
    @moduledoc "A plain module whose start_link starts no server. Quiet."

    def start_link(_opts) do
      :ets.new(:not_a_server_cache, [:named_table, :public])
      :ignore
    end
  end
end
