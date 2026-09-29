defmodule Argus.Test.Soundness.Census.Ets do
  @moduledoc """
  Suppression counterexamples and nearby variants: each program is the real
  bug an exclusion or a coarse fact hid. Asserted by
  test/soundness/ets_test.exs.
  """
end

# ── A table owner its supervisor never restarts ──────────────────────
#
# "ETS table dies with its owner" excused every owner a
# DynamicSupervisor.start_child starts, whatever restart the start gives
# it. A temporary child is never restarted: once it crashes its table is
# gone for good while callers go on reading it.

defmodule Argus.Test.Soundness.Census.Ets.TempOwner do
  @moduledoc "The census program: a temporary child started by its bare module."
  use GenServer, restart: :temporary

  @tab :census_ets_temp_owner

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public, :set, read_concurrency: true])
    {:ok, o}
  end

  def allowed?(k) do
    case :ets.lookup(@tab, k) do
      [{^k, n}] -> n < 100
      [] -> true
    end
  end

  @impl true
  def handle_cast({:hit, k}, s) do
    :ets.update_counter(@tab, k, 1, {k, 0})
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.TempTupleOwner do
  @moduledoc "A temporary child started by its `{Mod, arg}` shorthand."
  use GenServer, restart: :temporary

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(:census_ets_temp_tuple, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.MapTempOwner do
  @moduledoc "A child whose module states no restart, made temporary by the map spec."
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(:census_ets_map_temp, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.OverrideTempOwner do
  @moduledoc "A child made temporary by `Supervisor.child_spec/2`'s override."
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(:census_ets_override_temp, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.MapPermOwner do
  @moduledoc """
  Quiet: a temporary module a map spec with no `:restart` starts. The map
  does not call its child_spec/1: the child is permanent, and restarted.
  """
  use GenServer, restart: :temporary

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(:census_ets_map_perm, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.PermOwner do
  @moduledoc "Quiet: a module that states no restart, started by its shorthand."
  use GenServer

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(:census_ets_perm, [:named_table, :public])
    {:ok, o}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.Features do
  @moduledoc "Starts each owner on demand."
  alias Argus.Test.Soundness.Census.Ets

  @sup Argus.Test.Soundness.Census.Ets.DynSup

  def limiter, do: DynamicSupervisor.start_child(@sup, Ets.TempOwner)
  def tuple(o), do: DynamicSupervisor.start_child(@sup, {Ets.TempTupleOwner, o})

  def map_temp(o) do
    spec = %{
      id: Ets.MapTempOwner,
      start: {Ets.MapTempOwner, :start_link, [o]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(@sup, spec)
  end

  def override(o),
    do:
      DynamicSupervisor.start_child(
        @sup,
        Supervisor.child_spec({Ets.OverrideTempOwner, o}, restart: :temporary)
      )

  def map_perm(o) do
    spec = %{id: Ets.MapPermOwner, start: {Ets.MapPermOwner, :start_link, [o]}}
    DynamicSupervisor.start_child(@sup, spec)
  end

  def perm(o), do: DynamicSupervisor.start_child(@sup, {Ets.PermOwner, o})
end

# ── A computed-name table read by its owner and by its callers ───────
#
# "ETS table read while its owner may be restarting" judged a read of a
# table under a computed name only where the owner's process never ran
# the reader: a shard's `get/2` its own handle_call also runs was the
# shard's alone, though its callers run it too.

defmodule Argus.Test.Soundness.Census.Ets.Shard do
  @moduledoc "The census program: `get/2` runs in callers and in the shard's handle_call."
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @impl true
  def init(name) do
    :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    {:ok, name}
  end

  def get(name, k) do
    case :ets.lookup(name, k) do
      [{^k, v}] -> {:ok, v}
      [] -> :error
    end
  end

  def put(name, k, v), do: GenServer.call(name, {:put, k, v})

  @impl true
  def handle_call({:put, k, v}, _from, name) do
    :ets.insert(name, {k, v})
    {:reply, :ok, name}
  end

  def handle_call({:get_or_put, k, v}, _from, name) do
    case get(name, k) do
      {:ok, v0} ->
        {:reply, v0, name}

      :error ->
        :ets.insert(name, {k, v})
        {:reply, v, name}
    end
  end
end

defmodule Argus.Test.Soundness.Census.Ets.ShardSup do
  @moduledoc "Starts one shard per name."
  use Supervisor

  alias Argus.Test.Soundness.Census.Ets.Shard

  def start_link(shards), do: Supervisor.start_link(__MODULE__, shards, name: __MODULE__)

  @impl true
  def init(shards) do
    children = for s <- shards, do: Supervisor.child_spec({Shard, s}, id: s)
    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Argus.Test.Soundness.Census.Ets.NamedShared do
  @moduledoc """
  The same shape over a named table: `lookup/1` is its users' read and
  its own handle_call's.
  """
  use GenServer

  @tab :census_ets_named_shared

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o) do
    :ets.new(@tab, [:named_table, :public])
    {:ok, o}
  end

  def lookup(k), do: :ets.lookup(@tab, k)

  @impl true
  def handle_call({:touch, k}, _from, s) do
    rows = lookup(k)
    :ets.insert(@tab, {k, length(rows) + 1})
    {:reply, :ok, s}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.PeerShard do
  @moduledoc """
  A computed-name read another server of the program also runs, beside
  the shard's own handle_call: that server outlives a shard's crash.
  """
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @impl true
  def init(name) do
    :ets.new(name, [:named_table, :public])
    {:ok, name}
  end

  def get(name, k), do: :ets.lookup(name, k)

  @impl true
  def handle_call({:size, k}, _from, name), do: {:reply, length(get(name, k)), name}
end

defmodule Argus.Test.Soundness.Census.Ets.PeerReader do
  @moduledoc "Reads a peer shard's table from its own handle_info."
  use GenServer

  alias Argus.Test.Soundness.Census.Ets.PeerShard

  def start_link(o), do: GenServer.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(o), do: {:ok, o}

  @impl true
  def handle_info({:check, shard, k}, s) do
    _ = PeerShard.get(shard, k)
    {:noreply, s}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.PeerSup do
  @moduledoc "The peer shard beside its reader, one_for_one."
  use Supervisor

  alias Argus.Test.Soundness.Census.Ets.{PeerReader, PeerShard}

  def start_link(o), do: Supervisor.start_link(__MODULE__, o, name: __MODULE__)

  @impl true
  def init(_o) do
    Supervisor.init([{PeerShard, :census_peer_shard}, PeerReader], strategy: :one_for_one)
  end
end

defmodule Argus.Test.Soundness.Census.Ets.PrivateShard do
  @moduledoc """
  Quiet: a computed-name read only the shard's own callbacks run (a
  private helper), so no reader outlives the shard.
  """
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @impl true
  def init(name) do
    :ets.new(name, [:named_table, :public])
    {:ok, name}
  end

  @impl true
  def handle_call({:get, k}, _from, name), do: {:reply, get(name, k), name}

  defp get(name, k), do: :ets.lookup(name, k)
end

defmodule Argus.Test.Soundness.Census.Ets.ClientShard do
  @moduledoc """
  Quiet: a public computed-name read in a module the program calls into
  (`ShardClient` calls its `put/3`), which only the shard's own
  handle_call calls: its callers are in view, and none runs it.
  """
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, name, name: name)

  @impl true
  def init(name) do
    :ets.new(name, [:named_table, :public])
    {:ok, name}
  end

  def get(name, k), do: :ets.lookup(name, k)
  def put(name, k, v), do: GenServer.call(name, {:put, k, v})

  @impl true
  def handle_call({:put, k, v}, _from, name) do
    _ = get(name, k)
    :ets.insert(name, {k, v})
    {:reply, :ok, name}
  end
end

defmodule Argus.Test.Soundness.Census.Ets.ShardClient do
  @moduledoc "The client in view of `ClientShard`."
  def remember(shard, k, v), do: Argus.Test.Soundness.Census.Ets.ClientShard.put(shard, k, v)
end

# ── A named table a start function creates, beside a lookup of another ──
#
# "Named ETS table created in start_link fails the server's restart" took
# any `:ets.whereis/1` or `:ets.info/1,2` in the start function or the
# helper that creates the table as a guard, and any give-away of any
# table as handing it over.

defmodule Argus.Test.Soundness.Census.Ets.InfoSame do
  @moduledoc "The census program: start_link asks the size of another table first."
  use GenServer

  def start_link(opts) do
    opts =
      case :ets.info(:census_ets_app_config, :size) do
        :undefined -> opts
        _ -> Keyword.put_new(opts, :configured, true)
      end

    :ets.new(:census_ets_same_rows, [:named_table, :public, :set])
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Ets.InfoInStart do
  @moduledoc "The unrelated info in start_link, the create in a helper it calls."
  use GenServer

  def start_link(opts) do
    opts =
      case :ets.info(:census_ets_app_config, :size) do
        :undefined -> opts
        _ -> Keyword.put_new(opts, :configured, true)
      end

    create_table()
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  defp create_table, do: :ets.new(:census_ets_start_rows, [:named_table, :public, :set])

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Ets.WhereisAfter do
  @moduledoc """
  A whereis of the same table, asked after the create: nothing guards the
  make itself.
  """
  use GenServer

  def start_link(opts) do
    :ets.new(:census_ets_after_rows, [:named_table, :public])
    true = :ets.whereis(:census_ets_after_rows) != :undefined
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Ets.WhereisFoundSide do
  @moduledoc "The make on the found side of the same table's whereis: inverted."
  use GenServer

  def start_link(opts) do
    if :ets.whereis(:census_ets_inverted_rows) != :undefined do
      :ets.new(:census_ets_inverted_rows, [:named_table, :public])
    end

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Ets.GivesOtherAway do
  @moduledoc "Gives another table away, and keeps the one it creates."
  use GenServer

  def start_link(opts) do
    :ets.new(:census_ets_kept_rows, [:named_table, :public])
    :ets.give_away(:census_ets_handoff, Process.whereis(:census_ets_heir), :handoff)
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Ets.GuardedStart do
  @moduledoc "Quiet: the create only where the same table's whereis found none."
  use GenServer

  def start_link(opts) do
    if :ets.whereis(:census_ets_guarded_rows) == :undefined do
      :ets.new(:census_ets_guarded_rows, [:named_table, :public])
    end

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts), do: {:ok, opts}
end

defmodule Argus.Test.Soundness.Census.Ets.GuardedHelper do
  @moduledoc """
  Quiet: start_link calls the helper that makes the table only where the
  same table's info found none.
  """
  use GenServer

  def start_link(opts) do
    case :ets.info(:census_ets_helper_rows) do
      :undefined -> create_table()
      _ -> :ok
    end

    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  defp create_table, do: :ets.new(:census_ets_helper_rows, [:named_table, :public])

  @impl true
  def init(opts), do: {:ok, opts}
end
