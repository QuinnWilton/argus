defmodule Argus.Test.Fixtures.CheckThenAct do
  @moduledoc """
  Fixtures for the lookup-then-start race (`structure.registry_race`),
  the read-then-write race (`ets.ets_check_act`) and its Mnesia twin
  (`ets.mnesia_check_act`). The paper's own examples are Erlang, in
  `test/fixtures/erl/`.

  Behaviours are bare `@behaviour` attributes, as in `RequestSurface`.
  The positives are plain modules or many-instance callbacks; the quiet
  neighbours take the loser's outcome, or run in one process only.
  """

  # ── Lookup, then start ───────────────────────────────────────────

  defmodule WhereisThenStart do
    @moduledoc "A plain API: whereis, then a named start, in every caller's process."
    def ensure(name) do
      case Process.whereis(name) do
        nil ->
          {:ok, pid} = GenServer.start_link(__MODULE__, [], name: name)
          pid

        pid ->
          pid
      end
    end

    def init(state), do: {:ok, state}
  end

  defmodule LookupThenStartChild do
    @moduledoc "Registry.lookup, then DynamicSupervisor.start_child, the result returned untaken."
    def get_or_start(key) do
      case Registry.lookup(MyRegistry, key) do
        [{pid, _}] -> {:ok, pid}
        [] -> DynamicSupervisor.start_child(MySup, {Worker, key})
      end
    end
  end

  defmodule WhereisThenRegister do
    @moduledoc "whereis of a literal name, then register of the same literal."
    def claim do
      if Process.whereis(:leader) == nil do
        Process.register(self(), :leader)
      end
    end
  end

  defmodule ManyInstances do
    @moduledoc "A LiveView doing it: one process per socket."
    @behaviour Phoenix.LiveView

    def handle_event(_event, %{"room" => room}, socket) do
      case Registry.lookup(RoomRegistry, room) do
        [] -> DynamicSupervisor.start_child(RoomSup, {Room, room})
        [{pid, _}] -> {:ok, pid}
      end

      {:noreply, socket}
    end
  end

  defmodule LaterClauseName do
    @moduledoc "The racing clause is not the first: its parameters must survive the first clause's return."
    def ensure(:skip, _name), do: :skipped

    def ensure(_mode, name) do
      case Process.whereis(name) do
        nil ->
          {:ok, pid} = GenServer.start_link(__MODULE__, [], name: name)
          pid

        pid ->
          pid
      end
    end

    def init(state), do: {:ok, state}
  end

  defmodule AgentWhereisThenStart do
    @moduledoc "tesla#768's shape spelled with an Agent: whereis, then a named Agent start."
    def set(fun) do
      case Process.whereis(__MODULE__) do
        nil -> Agent.start_link(fn -> fun end, name: __MODULE__)
        pid -> Agent.update(pid, fn _ -> fun end)
      end
    end
  end

  # ── Across functions ─────────────────────────────────────────────

  defmodule LookupHelper do
    @moduledoc "The lookup sits in a helper that returns it; the decision is in the caller."
    def ensure(name) do
      case lookup(name) do
        nil -> GenServer.start_link(__MODULE__, [], name: name)
        pid -> {:ok, pid}
      end
    end

    defp lookup(name), do: Process.whereis(name)

    def init(state), do: {:ok, state}
  end

  defmodule StartHelper do
    @moduledoc "The decision calls a helper that starts the named process."
    def ensure(name) do
      case Process.whereis(name) do
        nil -> start(name)
        pid -> {:ok, pid}
      end
    end

    defp start(name), do: GenServer.start_link(__MODULE__, [], name: name)

    def init(state), do: {:ok, state}
  end

  defmodule DispatchHelper do
    @moduledoc "The lookup's result is an argument, and a multi-clause helper dispatches on it."
    def ensure(name), do: do_ensure(Process.whereis(name), name)

    defp do_ensure(nil, name), do: GenServer.start_link(__MODULE__, [], name: name)
    defp do_ensure(pid, _name), do: {:ok, pid}

    def init(state), do: {:ok, state}
  end

  defmodule NameDirectory do
    @moduledoc "A lookup helper in its own module."
    def whereis(name), do: Process.whereis(name)
  end

  defmodule NameStarter do
    @moduledoc "A start helper in its own module."
    def start(name), do: GenServer.start_link(__MODULE__, [], name: name)

    def init(state), do: {:ok, state}
  end

  defmodule AcrossModules do
    @moduledoc "The lookup and the start live in two other modules; they meet here."
    def ensure(name) do
      if NameDirectory.whereis(name) == nil do
        NameStarter.start(name)
      end
    end
  end

  defmodule UnregisterIfPresent do
    @moduledoc "whereis, then unregister: the name can go between the two."
    def release(name) do
      if Process.whereis(name) != nil do
        Process.unregister(name)
      end
    end
  end

  defmodule RegisterIfUnlisted do
    @moduledoc "Process.registered/0 decides a register: every name at once."
    def claim(name) do
      unless name in Process.registered() do
        Process.register(self(), name)
      end
    end
  end

  defmodule HelperTakesLoser do
    @moduledoc "The start helper takes {:error, {:already_started, pid}}."
    def ensure(name) do
      case Process.whereis(name) do
        nil -> start(name)
        pid -> {:ok, pid}
      end
    end

    defp start(name) do
      case GenServer.start_link(__MODULE__, [], name: name) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
      end
    end

    def init(state), do: {:ok, state}
  end

  defmodule HelperOtherName do
    @moduledoc "The helper starts a different name than the one looked up."
    def ensure(name) do
      case Process.whereis(name) do
        nil -> start(:somebody_else)
        pid -> {:ok, pid}
      end
    end

    defp start(name), do: GenServer.start_link(__MODULE__, [], name: name)

    def init(state), do: {:ok, state}
  end

  defmodule UnregisterRescued do
    @moduledoc "unregister's ArgumentError is the loser's outcome, and it is rescued."
    def release(name) do
      if Process.whereis(name) != nil do
        Process.unregister(name)
      end
    rescue
      ArgumentError -> :already_gone
    end
  end

  # ── Quiet neighbours ─────────────────────────────────────────────

  defmodule HandlesAlreadyStarted do
    @moduledoc "The loser's outcome is taken: {:error, {:already_started, pid}} becomes {:ok, pid}."
    def get_or_start(key) do
      case Registry.lookup(MyRegistry, key) do
        [{pid, _}] ->
          {:ok, pid}

        [] ->
          case DynamicSupervisor.start_child(MySup, {Worker, key}) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:already_started, pid}} -> {:ok, pid}
          end
      end
    end
  end

  defmodule AgentHandlesAlreadyStarted do
    @moduledoc "The named Agent start's loser takes the winner's pid."
    def set(fun) do
      case Process.whereis(__MODULE__) do
        nil ->
          case Agent.start_link(fn -> fun end, name: __MODULE__) do
            {:ok, pid} -> pid
            {:error, {:already_started, pid}} -> pid
          end

        pid ->
          pid
      end
    end
  end

  defmodule HandlesAlreadyRegistered do
    @moduledoc "Registry.register's own answer is taken."
    def claim(key) do
      case Registry.lookup(MyRegistry, key) do
        [] ->
          case Registry.register(MyRegistry, key, nil) do
            {:ok, _} -> :mine
            {:error, {:already_registered, _}} -> :theirs
          end

        _ ->
          :theirs
      end
    end
  end

  defmodule CallerHandlesAlreadyStarted do
    @moduledoc "The helper returns the start; its caller takes the outcome."
    def get_or_start(key) do
      case start(key) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    def start(key) do
      case Registry.lookup(MyRegistry, key) do
        [{pid, _}] -> {:ok, pid}
        [] -> DynamicSupervisor.start_child(MySup, {Worker, key})
      end
    end
  end

  defmodule OwnerRegisters do
    @moduledoc "Only the owner's own callbacks reach the decision: one process."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:claim, name}, _from, state) do
      case Process.whereis(name) do
        nil -> Process.register(self(), name)
        _pid -> :taken
      end

      {:reply, :ok, state}
    end
  end

  defmodule RescuesArgumentError do
    @moduledoc "register/2's ArgumentError is the loser's outcome, and it is rescued."
    def claim(name) do
      if Process.whereis(name) == nil do
        Process.register(self(), name)
      end
    rescue
      ArgumentError -> :theirs
    end
  end

  defmodule UncheckedWhereisThenStart do
    @moduledoc "No branch on the lookup: nothing decides the start."
    def start(name) do
      _ = Process.whereis(name)
      GenServer.start_link(__MODULE__, [], name: name)
    end

    def init(state), do: {:ok, state}
  end

  defmodule DifferentNames do
    @moduledoc "The lookup and the start name different processes."
    def start do
      if Process.whereis(:one) == nil do
        GenServer.start_link(__MODULE__, [], name: :two)
      end
    end

    def init(state), do: {:ok, state}
  end

  # ── Read, then write ─────────────────────────────────────────────

  defmodule PublicCache do
    @moduledoc "A public table, and an API that reads a key and inserts when it is absent."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:public_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def put_if_absent(key, value) do
      case :ets.lookup(:public_cache, key) do
        [] -> :ets.insert(:public_cache, {key, value})
        _ -> false
      end
    end
  end

  defmodule LaterBranchKey do
    @moduledoc "The write is in the last case branch, laid out after two returns."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:branch_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def bump(key, limit) do
      case :ets.lookup(:branch_cache, key) do
        [] -> :first
        [{_key, count}] when count >= limit -> :limited
        [{_key, count}] -> :ets.insert(:branch_cache, {key, count + 1})
      end
    end
  end

  defmodule InsertNewCache do
    @moduledoc "The atomic form: insert_new decides and writes at once."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:atomic_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def put_if_absent(key, value) do
      case :ets.lookup(:atomic_cache, key) do
        [] -> :ets.insert_new(:atomic_cache, {key, value})
        _ -> false
      end
    end
  end

  defmodule ProtectedOwnerOnly do
    @moduledoc "A protected table written only by its owner's callbacks: one writer."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:protected_cache, [:named_table, :protected, :set])
      {:ok, state}
    end

    @impl true
    def handle_call({:put_if_absent, key, value}, _from, state) do
      case :ets.lookup(:protected_cache, key) do
        [] -> :ets.insert(:protected_cache, {key, value})
        _ -> false
      end

      {:reply, :ok, state}
    end
  end

  defmodule BroadwayCount do
    @moduledoc """
    A Broadway pipeline's processors run handle_message/3 many at a time:
    its read-then-write count loses updates to itself, as a request
    handler's would.
    """
    @behaviour Broadway

    def start_link(_opts) do
      :ets.new(:broadway_counts, [:named_table, :public, :set])
      {:ok, self()}
    end

    @impl true
    def handle_message(_processor, message, _context) do
      case :ets.lookup(:broadway_counts, :seen) do
        [{:seen, n}] -> :ets.insert(:broadway_counts, {:seen, n + 1})
        [] -> :ets.insert(:broadway_counts, {:seen, 1})
      end

      message
    end
  end

  defmodule HelperCache do
    @moduledoc "A read helper and a write helper; the read's result is handed to the write."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:helper_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def bump(key), do: store(key, fetch(key))

    defp fetch(key), do: :ets.lookup(:helper_cache, key)

    defp store(key, []), do: :ets.insert(:helper_cache, {key, 1})
    defp store(key, [{_key, n}]), do: :ets.insert(:helper_cache, {key, n + 1})
  end

  defmodule CachedTwice do
    @moduledoc "A cache that meets its own read and fill, and a caller that decides the fill again on it."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:cached_twice, [:named_table, :public, :set])
      {:ok, state}
    end

    def warm(key) do
      if cached(key) == :missing, do: fill(key)
    end

    defp cached(key) do
      case :ets.lookup(:cached_twice, key) do
        [] -> fill(key)
        [{_key, value}] -> value
      end
    end

    defp fill(key) do
      :ets.insert(:cached_twice, {key, :filled})
      :missing
    end
  end

  defmodule UnnamedTable do
    @moduledoc "An unnamed public table handed to a helper by its reference."
    def start(key) do
      tab = :ets.new(:unnamed_counts, [:public])
      count(tab, key)
    end

    defp count(tab, key) do
      case :ets.lookup(tab, key) do
        [] -> :ets.insert(tab, {key, 1})
        [{^key, n}] -> :ets.insert(tab, {key, n + 1})
      end
    end
  end

  defmodule DifferentKeys do
    @moduledoc "The read and the write name different keys."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:keys_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def bump(key, other) do
      case :ets.lookup(:keys_cache, key) do
        [] -> :ets.insert(:keys_cache, {other, 1})
        _ -> false
      end
    end
  end

  # ── Dirty read, then dirty write ─────────────────────────────────

  # ── Races both racers win ──────────────────────────────────────────

  defmodule CacheRefill do
    @moduledoc """
    Cache-aside: a miss loads the value (from a function, or from Mnesia
    through a helper) and inserts it, an invalidation looks the row up and
    deletes it. Both racers load the same value, and
    deleting twice is deleting once.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:refill_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def get(key) do
      case :ets.lookup(:refill_cache, key) do
        [{^key, value}] ->
          value

        [] ->
          value = load(key)
          :ets.insert(:refill_cache, {key, value})
          value
      end
    end

    def setting(key) do
      case :ets.lookup(:refill_cache, key) do
        [{^key, value}] ->
          value

        [] ->
          case :mnesia.dirty_read({:settings, key}) do
            [{:settings, ^key, value}] -> put(key, value)
            [] -> nil
          end
      end
    end

    defp put(key, value) do
      :ets.insert(:refill_cache, {key, value})
      value
    end

    def invalidate(key) do
      case :ets.lookup(:refill_cache, key) do
        [{^key, _value}] -> :ets.delete(:refill_cache, key)
        [] -> true
      end
    end

    defp load(key), do: {:loaded, key, System.unique_integer()}
  end

  defmodule RefillWrittenBack do
    @moduledoc """
    The same refill on a table another function counts into, reading a
    row and writing it back one higher through a helper: the refill's
    insert can land on that count.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:counted_cache, [:named_table, :public, :set])
      {:ok, state}
    end

    def get(key) do
      case :ets.lookup(:counted_cache, key) do
        [{^key, value}] ->
          value

        [] ->
          value = load(key)
          :ets.insert(:counted_cache, {key, value})
          value
      end
    end

    def bump(key) do
      case :ets.lookup(:counted_cache, key) do
        [{^key, n}] -> :ets.insert(:counted_cache, {key, next(n)})
        [] -> :ets.insert(:counted_cache, {key, 1})
      end
    end

    defp next(n), do: n + 1

    defp load(_key), do: 0
  end

  defmodule Trip do
    @moduledoc """
    A circuit breaker (supavisor's): not tripped, so trip it. Both racers
    write the same block, and the decision stays inside: the one
    exported function says it returns :ok.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:blocks, [:named_table, :public, :set])
      {:ok, state}
    end

    @spec record(term()) :: :ok
    def record(key) do
      trip(key)
      :ok
    end

    defp trip(key) do
      case :ets.lookup(:blocks, key) do
        [] -> :ets.insert(:blocks, {key, :blocked})
        _ -> true
      end
    end
  end

  defmodule Claim do
    @moduledoc """
    blockster's sync slot: not claimed, so claim it, and tell the caller
    it may go on. Both racers are told they won.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:claims, [:named_table, :public, :set])
      {:ok, state}
    end

    def sync(key) do
      case claim(key) do
        :ok -> work(key)
        :skip -> :skipped
      end
    end

    defp claim(key) do
      case :ets.lookup(:claims, key) do
        [] ->
          :ets.insert(:claims, {key, :in_flight})
          :ok

        _ ->
          :skip
      end
    end

    defp work(key), do: {:worked, key}
  end

  defmodule CounterClobber do
    @moduledoc """
    Hammer's count_hit: member, then update_counter or a first insert.
    Two first hits both insert, and one's count is lost.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(:hits, [:named_table, :public, :set])
      {:ok, state}
    end

    def hit(key) do
      if :ets.member(:hits, key) do
        :ets.update_counter(:hits, key, {2, 1})
      else
        :ets.insert(:hits, {key, 1})
      end

      :ok
    end
  end

  defmodule MnesiaExpire do
    @moduledoc """
    blockster's OAuth state: read it, and delete it when expired. The
    table is otherwise only written fresh; deleting twice is deleting once.
    """
    def fetch(state, now) do
      case :mnesia.dirty_read({:oauth_states, state}) do
        [{:oauth_states, ^state, expires}] when expires > now ->
          :ok

        [_expired] ->
          :mnesia.dirty_delete({:oauth_states, state})
          :expired

        [] ->
          :none
      end
    end

    def store(state, expires), do: :mnesia.dirty_write({:oauth_states, state, expires})
  end

  defmodule MnesiaExpireCounted do
    @moduledoc """
    The same expiry on a table another function counts into, reading and
    writing back: the delete can remove a count made in between.
    """
    def fetch(key, now) do
      case :mnesia.dirty_read({:uses, key}) do
        [{:uses, ^key, _n, expires}] when expires > now -> :ok
        [_expired] -> :mnesia.dirty_delete({:uses, key})
        [] -> :none
      end
    end

    def use(key, expires) do
      case :mnesia.dirty_read({:uses, key}) do
        [{:uses, ^key, n, exp}] -> :mnesia.dirty_write({:uses, key, n + 1, exp})
        [] -> :mnesia.dirty_write({:uses, key, 1, expires})
      end
    end
  end

  defmodule MnesiaCounter do
    @moduledoc "A dirty read, one added, a dirty write: the paper's snmp counter in Elixir."
    def bump(key) do
      n =
        case :mnesia.dirty_read(:counters, key) do
          [] -> 0
          [{:counters, ^key, n}] -> n
        end

      :mnesia.dirty_write({:counters, key, n + 1})
    end
  end

  defmodule MnesiaHelpers do
    @moduledoc "The read and the write sit in helpers; the read's result is handed to the write."
    def bump(key), do: put(key, get(key))

    defp get(key), do: :mnesia.dirty_read({:counters, key})

    defp put(key, []), do: :mnesia.dirty_write(:counters, {:counters, key, 1})

    defp put(key, [{:counters, _key, n}]),
      do: :mnesia.dirty_write(:counters, {:counters, key, n + 1})
  end

  defmodule MnesiaComputedKey do
    @moduledoc "The key is built at runtime and handed to the read and the write alike."
    def put(name, type, record) do
      key = {String.downcase(name), type}

      case :mnesia.dirty_read(:records, key) do
        [{:records, _key, existing}] when existing.serial >= record.serial -> {:error, :stale}
        _ -> :mnesia.dirty_write({:records, key, record})
      end
    end
  end

  defmodule MnesiaJoinedKey do
    @moduledoc "The write's key is one of two values chosen after the read: not the read's key."
    def put(name, record, fresh?) do
      key = {name, :a}

      case :mnesia.dirty_read(:records, key) do
        [] ->
          other = if fresh?, do: {name, :b}, else: {name, :c}
          :mnesia.dirty_write({:records, other, record})

        _ ->
          :ok
      end
    end
  end

  defmodule MnesiaTransaction do
    @moduledoc "The same counter in a transaction: nothing dirty."
    def bump(key) do
      :mnesia.transaction(fn ->
        n =
          case :mnesia.read(:counters, key) do
            [] -> 0
            [{:counters, ^key, n}] -> n
          end

        :mnesia.write({:counters, key, n + 1})
      end)
    end
  end

  defmodule MnesiaUpdateCounter do
    @moduledoc "The atomic form."
    def bump(key), do: :mnesia.dirty_update_counter(:counters, key, 1)
  end

  defmodule MnesiaOtherKey do
    @moduledoc "The read and the write name different records."
    def copy(from, to) do
      case :mnesia.dirty_read(:counters, from) do
        [{:counters, _, n}] -> :mnesia.dirty_write({:counters, to, n})
        [] -> :ok
      end
    end
  end

  defmodule MnesiaOwner do
    @moduledoc "Only the owner's callbacks touch the table: one writer."
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:bump, key}, _from, state) do
      n =
        case :mnesia.dirty_read(:owned_counters, key) do
          [] -> 0
          [{:owned_counters, ^key, n}] -> n
        end

      :mnesia.dirty_write({:owned_counters, key, n + 1})
      {:reply, :ok, state}
    end
  end
end
