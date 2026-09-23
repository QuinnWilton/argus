defmodule Argus.Test.Fixtures.CheckThenAct do
  @moduledoc """
  Fixtures for the lookup-then-start race (`structure.registry_race`)
  and the read-then-write race (`ets.ets_check_act`). The paper's own
  examples are Erlang, in `test/fixtures/erl/`.

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
end
