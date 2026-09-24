defmodule Argus.Test.Fixtures.CheckThenAct do
  @moduledoc """
  Fixtures for the lookup-then-start race (`races.registry_race`),
  the read-then-write race (`races.ets_check_act`) and its Mnesia twin
  (`races.mnesia_check_act`). The paper's own examples are Erlang, in
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

  defmodule NestedDecision do
    @moduledoc "A start decided by a test that the lookup's test decides in turn."
    def ensure(name) do
      case Process.whereis(name) do
        nil ->
          case :persistent_term.get(:enabled, false) do
            true -> GenServer.start_link(__MODULE__, [], name: name)
            false -> :disabled
          end

        pid ->
          {:ok, pid}
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

  defmodule OwnerSpawnsClaims do
    @moduledoc """
    The owner's handler hands each claim to a task: one task per call,
    and two can claim at once.
    """
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:claim, name}, state) do
      Task.start(fn -> claim(name) end)
      {:noreply, state}
    end

    defp claim(name) do
      case Process.whereis(name) do
        nil -> Process.register(self(), name)
        _pid -> :taken
      end
    end
  end

  defmodule OwnerSpawnsClaimer do
    @moduledoc "init/1 spawns one worker that makes the claim: one process."
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, name, name: __MODULE__)

    @impl true
    def init(name) do
      pid = spawn_link(fn -> claim(name) end)
      {:ok, pid}
    end

    defp claim(name) do
      case Process.whereis(name) do
        nil -> Process.register(self(), name)
        _pid -> :taken
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

  defmodule SerializedSessionCache do
    @moduledoc """
    nerves_hub_web's CLISessionCache: a public table whose read-then-write
    runs in the owner's handle_call/3, so callers never interleave it. The
    other writers are the owner's own callbacks, and an exported clear/0
    nothing in the program calls (nerves_hub_web's tests do).
    """
    use GenServer

    @table :serialized_sessions

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]) do
      _ = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      Process.send_after(self(), :sweep, 60_000)
      {:ok, %{}}
    end

    def get_and_update(key, fun), do: GenServer.call(__MODULE__, {:get_and_update, key, fun})

    @impl true
    def handle_call({:get_and_update, key, fun}, _from, state) do
      case fun.(get(key)) do
        {return, {:put, session}} ->
          :ok = put(key, session)
          {:reply, return, state}

        {return, :noop} ->
          {:reply, return, state}
      end
    end

    @impl true
    def handle_info({:put, key, session}, state) do
      :ets.insert(@table, {key, session, session.expires_at})
      {:noreply, state}
    end

    def handle_info(:sweep, state) do
      now = System.system_time(:second)
      :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
      Process.send_after(self(), :sweep, 60_000)
      {:noreply, state}
    end

    def put(key, session) do
      :ets.insert(@table, {key, session, session.expires_at})
      :ok
    end

    def get(key) do
      case :ets.lookup(@table, key) do
        [{^key, session, _expires_at}] -> {:ok, session}
        [] -> :error
      end
    end

    def clear do
      :ets.delete_all_objects(@table)
      :ok
    end
  end

  defmodule SessionAccounts do
    @moduledoc """
    SerializedSessionCache's client in the program, as nerves_hub_web's
    Accounts is CLISessionCache's: with it in view, clear/0 is a function
    no caller in the program calls, not API.
    """
    alias Argus.Test.Fixtures.CheckThenAct.SerializedSessionCache

    def confirm(token) do
      SerializedSessionCache.get_and_update(token, fn
        {:ok, session} -> {:ok, {:put, %{session | confirmed: true}}}
        :error -> {{:error, :not_found}, :noop}
      end)
    end

    def fetch(token), do: SerializedSessionCache.get(token)
  end

  defmodule SessionReaper do
    @moduledoc """
    A second process that deletes SerializedSessionCache's rows: a session
    it revokes between the owner's read and write is written back.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]), do: {:ok, %{}}

    @impl true
    def handle_cast({:revoke, key}, state) do
      :ets.delete(:serialized_sessions, key)
      {:noreply, state}
    end
  end

  defmodule SessionImporter do
    @moduledoc "A second process that inserts into SerializedSessionCache's table."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]), do: {:ok, %{}}

    @impl true
    def handle_cast({:import, key, session}, state) do
      :ets.insert(:serialized_sessions, {key, session, session.expires_at})
      {:noreply, state}
    end
  end

  defmodule SessionAdmin do
    @moduledoc """
    A module nothing in the program calls into, whose exported function
    clears SerializedSessionCache: API for callers outside the program.
    """
    alias Argus.Test.Fixtures.CheckThenAct.SerializedSessionCache

    def reset_all, do: SerializedSessionCache.clear()
  end

  defmodule SeedingOwner do
    @moduledoc """
    Creates the counters' table and seeds a row in its own init/1, before
    its supervisor starts SerializedCounter.
    """
    use GenServer

    def start_link(first), do: GenServer.start_link(__MODULE__, first, name: __MODULE__)

    @impl true
    def init(first) do
      :ets.new(:serialized_counts, [:named_table, :public])
      :ets.insert(:serialized_counts, {first, 0})
      {:ok, %{}}
    end
  end

  defmodule SerializedCounter do
    @moduledoc "Every bump serialized in its own handle_call/3: the only writer once it runs."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]), do: {:ok, %{}}

    @impl true
    def handle_call({:bump, k}, _from, state) do
      case :ets.lookup(:serialized_counts, k) do
        [{^k, n}] -> :ets.insert(:serialized_counts, {k, n + 1})
        [] -> :ets.insert(:serialized_counts, {k, 1})
      end

      {:reply, :ok, state}
    end
  end

  defmodule VersionStamper do
    @moduledoc "Another process that writes a literal row of its own beside the counts."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]), do: {:ok, %{}}

    @impl true
    def handle_cast({:stamp, version}, state) do
      :ets.insert(:serialized_counts, {:__version__, version})
      {:noreply, state}
    end
  end

  defmodule CountImporter do
    @moduledoc "Another process that writes counts by key while the counter runs."
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]), do: {:ok, %{}}

    @impl true
    def handle_cast({:import, k, n}, state) do
      :ets.insert(:serialized_counts, {k, n})
      {:noreply, state}
    end
  end

  defmodule RecordTable do
    @moduledoc """
    A read-modify-write on a table of Elixir records, keyed by the
    record's second element (`keypos: 2`): the insert's key is the id,
    not the record's tag.
    """
    require Record
    Record.defrecord(:acct, id: nil, balance: 0)

    def start, do: :ets.new(:accts, [:named_table, :public, keypos: 2])

    def deposit(id, amount) do
      case :ets.lookup(:accts, id) do
        [acct(balance: balance)] -> :ets.insert(:accts, acct(id: id, balance: balance + amount))
        [] -> :ets.insert(:accts, acct(id: id, balance: amount))
      end
    end
  end

  defmodule MatchThenWrite do
    @moduledoc "A match on the key decides the write, as a lookup would."
    def start, do: :ets.new(:matched_counts, [:named_table, :public])

    def bump(k) do
      case :ets.match_object(:matched_counts, {k, :_}) do
        [{^k, n}] -> :ets.insert(:matched_counts, {k, n + 1})
        [] -> :ets.insert(:matched_counts, {k, 1})
      end
    end

    def owned_by(owner) do
      case :ets.match_object(:matched_counts, {:_, owner}) do
        [] -> :ets.insert(:matched_counts, {owner, 0})
        _ -> true
      end
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

    defp load(key), do: {:loaded, key}
  end

  defmodule TokenMint do
    @moduledoc """
    A refill that mints a token and hands it out: each racer returns its
    own token, and only one of them is stored.
    """
    def start, do: :ets.new(:tokens, [:named_table, :public])

    def token(user) do
      case :ets.lookup(:tokens, user) do
        [{^user, token}] ->
          token

        [] ->
          token = Base.encode64(:crypto.strong_rand_bytes(16))
          :ets.insert(:tokens, {user, token})
          token
      end
    end
  end

  defmodule IdMint do
    @moduledoc "The same refill, the value minted in a helper: a unique id."
    def start, do: :ets.new(:ids, [:named_table, :public])

    def id(name) do
      case :ets.lookup(:ids, name) do
        [{^name, id}] ->
          id

        [] ->
          id = new_id()
          :ets.insert(:ids, {name, id})
          id
      end
    end

    defp new_id, do: {:id, System.unique_integer([:positive])}
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

  defmodule CacheWithHits do
    @moduledoc """
    A cache-aside refill on a table that also counts hits, in a literal row
    of its own: the count can never land on a cached key's row.
    """
    def start, do: :ets.new(:hit_cache, [:named_table, :public])

    def get(key) do
      :ets.update_counter(:hit_cache, :__hits__, {2, 1}, {:__hits__, 0})

      case :ets.lookup(:hit_cache, key) do
        [{^key, value}] ->
          value

        [] ->
          value = load(key)
          :ets.insert(:hit_cache, {key, value})
          value
      end
    end

    defp load(key), do: {:loaded, key}
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

  defmodule SerialsOk do
    @moduledoc """
    The talk's Serials with both branches returning :ok: the guard on the
    stored serial still lets the older serial land last, whatever the
    racers are told.
    """
    def start, do: :ets.new(:serials_ok, [:named_table, :public])

    @spec put(term(), integer()) :: :ok
    def put(k, serial) do
      case :ets.lookup(:serials_ok, k) do
        [{^k, cur}] when cur >= serial ->
          :ok

        _ ->
          :ets.insert(:serials_ok, {k, serial})
          :ok
      end
    end
  end

  defmodule NotifyOnce do
    @moduledoc """
    An idempotency marker whose decision also sends: both racers mark the
    id, and both send the charge.
    """
    def start, do: :ets.new(:notified, [:named_table, :public])

    @spec handle(term(), term()) :: :ok
    def handle(id, payload) do
      case :ets.lookup(:notified, id) do
        [] ->
          :ets.insert(:notified, {id, true})
          send(:mailer, {:charge, payload})
          :ok

        _ ->
          :ok
      end
    end
  end

  defmodule BreakerTrip do
    @moduledoc """
    supavisor's CircuitBreaker.record_failures/3: not blocked (the stored
    block has expired, against the clock), so record the failure and trip
    the block, and have a helper tell the other nodes. Both racers write
    the same block and send the same news.
    """
    require Logger

    def start, do: :ets.new(:breaker_blocks, [:named_table, :public])

    @spec record_failure(term()) :: :ok
    def record_failure(key) do
      now = System.system_time(:second)

      case :ets.lookup(:breaker_blocks, key) do
        [{^key, blocked}] when blocked > now ->
          :ok

        _ ->
          if count(key) >= 5 do
            :ets.insert(:breaker_blocks, {key, now + 30})
            Logger.warning("breaker opened for #{inspect(key)}")
            tell_nodes(key, now + 30)
          end

          :ok
      end
    end

    defp count(key), do: :erlang.phash2(key, 10)

    defp tell_nodes(key, until) do
      for node <- Node.list(), do: send({__MODULE__, node}, {:open, key, until})
      :ok
    end
  end

  defmodule ExpiringCache do
    @moduledoc """
    A cache whose rows expire: a read that finds an expired row deletes it.
    Every row the table holds is a refill, so a row deleted in the window
    is a cached copy, and losing one is a miss.
    """
    def start, do: :ets.new(:expiring_cache, [:named_table, :public])

    def get(key, now) do
      case :ets.lookup(:expiring_cache, key) do
        [{^key, value, expires}] when expires > now ->
          value

        [{^key, _value, _expires}] ->
          :ets.delete(:expiring_cache, key)
          nil

        [] ->
          value = load(key)
          :ets.insert(:expiring_cache, {key, value, now + 60})
          value
      end
    end

    defp load(key), do: {:loaded, key}
  end

  defmodule LockRelease do
    @moduledoc """
    A release that checks the owner, then deletes by key: another process
    that took the lock in between loses it to the delete.
    """
    def start, do: :ets.new(:locks, [:named_table, :public])

    def acquire(lock, owner), do: :ets.insert_new(:locks, {lock, owner})

    def release(lock, owner) do
      case :ets.lookup(:locks, lock) do
        [{^lock, ^owner}] -> :ets.delete(:locks, lock)
        _ -> false
      end
    end
  end

  defmodule LockReleaseObject do
    @moduledoc "The same release with delete_object: it deletes only the owner's own row."
    def start, do: :ets.new(:object_locks, [:named_table, :public])

    def acquire(lock, owner), do: :ets.insert_new(:object_locks, {lock, owner})

    def release(lock, owner) do
      case :ets.lookup(:object_locks, lock) do
        [{^lock, ^owner}] -> :ets.delete_object(:object_locks, {lock, owner})
        _ -> false
      end
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

  defmodule MnesiaPutElem do
    @moduledoc "The counter updated in place: put_elem on the record the read found."
    def bump(key) do
      [rec] = :mnesia.dirty_read(:counters, key)
      :mnesia.dirty_write(put_elem(rec, 2, elem(rec, 2) + 1))
    end
  end

  defmodule MnesiaRecordUpdate do
    @moduledoc "The same with an Elixir record's update."
    require Record
    Record.defrecord(:counter, key: nil, n: 0)

    def bump(key) do
      [c] = :mnesia.dirty_read({:counters, key})
      :mnesia.dirty_write(counter(c, n: counter(c, :n) + 1))
    end
  end

  defmodule MnesiaHelperUpdate do
    @moduledoc """
    blockster's update_user_betting_stats: the record the read found is
    updated by a helper's put_elem pipeline and written back.
    """
    def record_bet(user, amount) do
      case :mnesia.dirty_read(:betting_stats, user) do
        [record] -> :mnesia.dirty_write(add_bet(record, amount))
        [] -> :ok
      end
    end

    defp add_bet(record, amount) do
      record
      |> put_elem(2, elem(record, 2) + 1)
      |> put_elem(3, elem(record, 3) + amount)
    end
  end

  defmodule MnesiaPutElemKey do
    @moduledoc "An update that sets the key: another record's, not the one read."
    def copy(from, to) do
      [rec] = :mnesia.dirty_read(:counters, from)
      :mnesia.dirty_write(put_elem(rec, 1, to))
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

  defmodule MnesiaOwnerResetter do
    @moduledoc "Resets MnesiaOwner's counters from any caller, through a helper handed the record."
    def reset(key), do: save({:owned_counters, key, 0})

    defp save(record), do: :mnesia.dirty_write(record)
  end

  defmodule MnesiaOwnerTxnResetter do
    @moduledoc "Resets MnesiaOwner's counters in a transaction, which a dirty write does not wait for."
    def reset(key), do: :mnesia.transaction(fn -> :mnesia.write({:owned_counters, key, 0}) end)
  end

  defmodule MnesiaOwnerCounter do
    @moduledoc "Counts into MnesiaOwner's table with the atomic counter, from any caller."
    def bump(key), do: :mnesia.dirty_update_counter(:owned_counters, key, 1)
  end

  defmodule MnesiaExpireSaved do
    @moduledoc """
    MnesiaExpireCounted with the write-back through a helper handed the
    whole record: the delete can still remove a use counted in between.
    """
    def fetch(key, now) do
      case :mnesia.dirty_read({:saved_uses, key}) do
        [{:saved_uses, ^key, _n, expires}] when expires > now -> :ok
        [_expired] -> :mnesia.dirty_delete({:saved_uses, key})
        [] -> :none
      end
    end

    def use(key, expires) do
      case :mnesia.dirty_read({:saved_uses, key}) do
        [{:saved_uses, ^key, n, exp}] -> save({:saved_uses, key, n + 1, exp})
        [] -> save({:saved_uses, key, 1, expires})
      end
    end

    defp save(record), do: :mnesia.dirty_write(record)
  end

  defmodule MnesiaExpireHits do
    @moduledoc "An expiry on a table another function counts into with dirty_update_counter."
    def fetch(key, now) do
      case :mnesia.dirty_read({:hits, key}) do
        [{:hits, ^key, _n, expires}] when expires > now -> :ok
        [_expired] -> :mnesia.dirty_delete({:hits, key})
        [] -> :none
      end
    end

    def hit(key), do: :mnesia.dirty_update_counter(:hits, key, 1)
  end

  defmodule MnesiaRecordHelper do
    @moduledoc """
    elvengard_ecs's insert_new before its fix: the helper reads by the
    record's table and key, handed in as elements, and writes the record
    itself. Only the caller, which builds the record, says they are one.
    """
    def create(id, value) do
      case insert_new({:entities, id, value}) do
        :ok -> {:ok, id}
        error -> error
      end
    end

    defp insert_new(record), do: do_insert_new(elem(record, 0), elem(record, 1), record)

    defp do_insert_new(type, key, record) do
      case :mnesia.dirty_read({type, key}) do
        [] -> :mnesia.dirty_write(record)
        _ -> {:error, :already_exists}
      end
    end
  end

  defmodule MnesiaRecordOther do
    @moduledoc "The helper reads one record's key and writes another record: never the same."
    def copy(id, other_id, value) do
      put_if_absent({:entities, id, value}, {:entities, other_id, value})
    end

    defp put_if_absent(probe, record) do
      case :mnesia.dirty_read({elem(probe, 0), elem(probe, 1)}) do
        [] -> :mnesia.dirty_write(record)
        _ -> :exists
      end
    end
  end

  defmodule MnesiaMatchThenWrite do
    @moduledoc "A match on the key decides the write: dirty_match_object is a read too."
    def claim(id, owner) do
      case :mnesia.dirty_match_object({:claims, id, :_}) do
        [] -> :mnesia.dirty_write({:claims, id, owner})
        _ -> {:error, :taken}
      end
    end
  end

  defmodule MnesiaIndexThenWrite do
    @moduledoc "A lookup by a secondary index decides the write of a new record: every key is read."
    def register(email, id) do
      case :mnesia.dirty_index_read(:users, email, :email) do
        [] -> :mnesia.dirty_write({:users, id, email})
        _ -> {:error, :taken}
      end
    end
  end
end
