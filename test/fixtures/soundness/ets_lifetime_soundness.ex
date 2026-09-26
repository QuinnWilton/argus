defmodule Lifetime do
  @moduledoc """
  Readers that do and do not outlive the owner of the table they read
  (ets.dl's reader_outlives, supervision.dl's ends_with,
  docs/design/restart-state.md), and reads the reader makes safe by
  making the table on its way (ets_read_when_present). Asserted by
  test/soundness/ets_lifetime_test.exs.
  """

  @doc false
  def table_opts, do: [:named_table, :public]
end

# ── A reader its owner's supervisor ends with it ──────────────────────

defmodule Lifetime.OwnerSup do
  @moduledoc "A supervisor whose init/1 makes a table its child reads."
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg) do
    :ets.new(:lt_sup_tab, [:named_table, :public])
    Supervisor.init([Lifetime.SupChild], strategy: :one_for_one)
  end
end

defmodule Lifetime.SupChild do
  @moduledoc "Reads its supervisor's table: it is in the supervisor's subtree."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, :ets.lookup(:lt_sup_tab, k), s}
end

defmodule Lifetime.AllSup do
  @moduledoc false
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Lifetime.AllOwner, Lifetime.AllReader], strategy: :one_for_all)
end

defmodule Lifetime.AllOwner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_all_tab, [:named_table, :public])
    {:ok, nil}
  end
end

defmodule Lifetime.AllReader do
  @moduledoc "A one_for_all sibling: the owner's crash restarts it too."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, :ets.lookup(:lt_all_tab, k), s}
end

defmodule Lifetime.RestSup do
  @moduledoc false
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do:
      Supervisor.init([Lifetime.RestEarlier, Lifetime.RestOwner, Lifetime.RestLater],
        strategy: :rest_for_one
      )
end

defmodule Lifetime.RestOwner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_rest_tab, [:named_table, :public])
    {:ok, nil}
  end
end

defmodule Lifetime.RestEarlier do
  @moduledoc "Started before the owner under rest_for_one: the owner's crash leaves it running."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, :ets.lookup(:lt_rest_tab, k), s}
end

defmodule Lifetime.RestLater do
  @moduledoc "Started after the owner under rest_for_one: restarted with it."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:peek, k}, _from, s), do: {:reply, :ets.lookup(:lt_rest_tab, k), s}
end

# ── Readers that outlive the owner ────────────────────────────────────

defmodule Lifetime.OneSup do
  @moduledoc false
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Lifetime.OneOwner, Lifetime.OneReader], strategy: :one_for_one)
end

defmodule Lifetime.OneOwner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_one_tab, [:named_table, :public])
    {:ok, nil}
  end
end

defmodule Lifetime.OneReader do
  @moduledoc "A one_for_one sibling: it runs on while the owner restarts."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, :ets.lookup(:lt_one_tab, k), s}
end

defmodule Lifetime.DeepAllSup do
  @moduledoc "one_for_all over a branch whose own supervisor restarts the owner alone."
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Lifetime.DeepBranch, Lifetime.DeepReader], strategy: :one_for_all)
end

defmodule Lifetime.DeepBranch do
  @moduledoc false
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg), do: Supervisor.init([Lifetime.DeepOwner], strategy: :one_for_one)
end

defmodule Lifetime.DeepOwner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_deep_tab, [:named_table, :public])
    {:ok, nil}
  end
end

defmodule Lifetime.DeepReader do
  @moduledoc "The owner's crash restarts it in its own branch; the reader runs on."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, :ets.lookup(:lt_deep_tab, k), s}
end

defmodule Lifetime.LinkOwner do
  @moduledoc """
  Spawns a linked loader that reads its table: the link ends the loader
  with it. The loader is private: a public one would be its users' read
  too (a way in from outside the program), which outlives the owner.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_link_tab, [:named_table, :public])
    spawn_link(fn -> load() end)
    {:ok, nil}
  end

  defp load, do: :ets.lookup(:lt_link_tab, :seed)
end

defmodule Lifetime.UnlinkOwner do
  @moduledoc "Spawns an unlinked loader that reads its table: the loader runs on."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_unlink_tab, [:named_table, :public])
    spawn(fn -> load() end)
    {:ok, nil}
  end

  def load, do: :ets.lookup(:lt_unlink_tab, :seed)
end

defmodule Lifetime.SharedSup do
  @moduledoc false
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  @impl true
  def init(_arg),
    do: Supervisor.init([Lifetime.SharedOwner, Lifetime.SharedClient], strategy: :one_for_one)
end

defmodule Lifetime.SharedOwner do
  @moduledoc """
  Reads its own table in a callback and through `lookup/1`, which a
  sibling also calls: the sibling runs the read after the owner is gone.
  """
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def lookup(k), do: :ets.lookup(:lt_shared_tab, k)

  @impl true
  def init(_) do
    :ets.new(:lt_shared_tab, [:named_table, :public])
    {:ok, nil}
  end

  @impl true
  def handle_call({:get, k}, _from, s), do: {:reply, lookup(k), s}
end

defmodule Lifetime.SharedClient do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_), do: {:ok, nil}

  @impl true
  def handle_call({:ask, k}, _from, s), do: {:reply, Lifetime.SharedOwner.lookup(k), s}
end

# ── A reader that makes the table on its way ──────────────────────────

defmodule Lifetime.EnsureOwner do
  @moduledoc false
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(:lt_ensure_tab, [:named_table, :public])
    {:ok, nil}
  end
end

defmodule Lifetime.EnsureReader do
  @moduledoc """
  Reads EnsureOwner's table from callers' processes. Made safe: an
  ensure helper before the read, a whereis-or-make inline. Not made safe:
  an ensure on one branch only, an ensure after the read, an ensure of
  another table, an ensure that makes an unnamed table of the atom.
  """

  def get(k) do
    ensure()
    :ets.lookup(:lt_ensure_tab, k)
  end

  def get_inline(k) do
    case :ets.whereis(:lt_ensure_tab) do
      :undefined -> :ets.new(:lt_ensure_tab, [:named_table, :public])
      _ -> :ok
    end

    :ets.lookup(:lt_ensure_tab, k)
  end

  def get_branch(k, fresh?) do
    if fresh?, do: ensure()
    :ets.lookup(:lt_ensure_tab, k)
  end

  def get_after(k) do
    row = :ets.lookup(:lt_ensure_tab, k)
    ensure()
    row
  end

  def get_other(k) do
    ensure_other()
    :ets.lookup(:lt_ensure_tab, k)
  end

  def get_unnamed(k) do
    ensure_unnamed()
    :ets.lookup(:lt_ensure_tab, k)
  end

  defp ensure do
    if :ets.whereis(:lt_ensure_tab) == :undefined,
      do: :ets.new(:lt_ensure_tab, [:named_table, :public])

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_other do
    if :ets.whereis(:lt_other_tab) == :undefined,
      do: :ets.new(:lt_other_tab, [:named_table, :public])

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp ensure_unnamed do
    :ets.new(:lt_ensure_tab, [:public])
    :ok
  end
end
