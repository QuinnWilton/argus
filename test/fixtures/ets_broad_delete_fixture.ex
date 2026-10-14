defmodule Argus.Test.Fixtures.EtsBroadDelete do
  @moduledoc """
  Fixtures for deletes by key that take rows other processes made
  (`races.ets_broad_delete`): roux 0.3.4's `release_dedup/2`, which read a
  key's waiters and then deleted the key, and its `kill_task/4`, which
  killed a task and then deleted the task's key; each beside its fix and
  the deletes by key that take nobody else's row.
  """

  defmodule ReleaseWaiters do
    @moduledoc """
    Each waiter registers its own row under the key; the release reads the
    rows, deletes the key and wakes the waiters it read. A waiter that
    registers between the read and the delete loses its row and is never
    woken.
    """
    def start, do: :ets.new(:release_waiters, [:named_table, :public, :duplicate_bag])

    def wait(key) do
      :ets.insert(:release_waiters, {key, self()})

      receive do
        {:done, ^key} -> :ok
      end
    end

    def release(key) do
      waiters = :ets.lookup(:release_waiters, key)
      :ets.delete(:release_waiters, key)
      Enum.each(waiters, fn {^key, pid} -> send(pid, {:done, key}) end)
    end
  end

  defmodule ReleaseReadWaiters do
    @moduledoc "The fix: delete exactly the rows read, and a later waiter's row stays."
    def start, do: :ets.new(:read_waiters, [:named_table, :public, :duplicate_bag])

    def wait(key) do
      :ets.insert(:read_waiters, {key, self()})

      receive do
        {:done, ^key} -> :ok
      end
    end

    def release(key) do
      waiters = :ets.lookup(:read_waiters, key)
      Enum.each(waiters, &:ets.delete_object(:read_waiters, &1))
      Enum.each(waiters, fn {^key, pid} -> send(pid, {:done, key}) end)
    end
  end

  defmodule CancelClaim do
    @moduledoc """
    A claimant holds the key with its own row; the canceller kills it and
    deletes the key. Between the two another process can claim the key,
    and the delete takes the new claim.
    """
    def start, do: :ets.new(:cancel_claims, [:named_table, :public])

    def claim(key), do: :ets.insert_new(:cancel_claims, {key, self()})

    def cancel(key, pid) do
      Process.exit(pid, :kill)
      :ets.delete(:cancel_claims, key)
    end
  end

  defmodule CancelOwnRow do
    @moduledoc "The fix: delete the killed claimant's own row, and a new claim stays."
    def start, do: :ets.new(:own_row_claims, [:named_table, :public])

    def claim(key), do: :ets.insert_new(:own_row_claims, {key, self()})

    def cancel(key, pid) do
      Process.exit(pid, :kill)
      :ets.delete_object(:own_row_claims, {key, pid})
    end
  end

  defmodule ReleaseOwnClaim do
    @moduledoc """
    A claimant releases its own claim by key, neither after a read nor
    after a kill: the row under the key is the one it made.
    """
    def start, do: :ets.new(:own_claims, [:named_table, :public])

    def claim(key), do: :ets.insert_new(:own_claims, {key, self()})

    def release(key), do: :ets.delete(:own_claims, key)
  end

  defmodule OwnerCancels do
    @moduledoc """
    The table's owner alone writes it (`:protected`): it kills a worker and
    deletes the worker's key, and no other process can claim the key in
    between.
    """
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

    @impl true
    def init([]) do
      :ets.new(:owner_claims, [:named_table, :protected])
      {:ok, %{}}
    end

    @impl true
    def handle_call({:claim, key}, _from, state) do
      {:reply, :ets.insert_new(:owner_claims, {key, self()}), state}
    end

    def handle_call({:cancel, key, pid}, _from, state) do
      Process.exit(pid, :kill)
      :ets.delete(:owner_claims, key)
      {:reply, :ok, state}
    end
  end

  defmodule TaskTables do
    @moduledoc """
    roux's shape: the claims and the waiters are two of the tables one
    closure makes, kept under fields of one struct. The canceller kills the
    claimant and deletes the key from both; the waiters' release reads them
    and deletes the key.
    """
    defstruct [:claims, :waiters]

    def new do
      tables =
        Map.new([claims: :set, waiters: :duplicate_bag], fn {name, type} ->
          {name, :ets.new(name, [type, :public])}
        end)

      %__MODULE__{claims: tables.claims, waiters: tables.waiters}
    end

    def run(key) do
      db = new()
      spawn(fn -> claim(db, key) end)
      spawn(fn -> wait(db, key) end)
      cancel(db, key, self())
    end

    def claim(db, key), do: :ets.insert_new(db.claims, {key, self()})

    def wait(db, key) do
      :ets.insert(db.waiters, {key, self()})

      receive do
        {:done, ^key} -> :ok
      end
    end

    def cancel(db, key, pid) do
      Process.exit(pid, :kill)
      :ets.delete(db.claims, key)
      :ets.delete(db.waiters, key)
    end
  end
end
