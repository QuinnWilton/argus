defmodule Argus.Test.Fixtures.RacesExposureClaim do
  @moduledoc """
  A claim makes the row on the side of the read that found none. A write
  reached only where the read found the row, or without the read, is an
  overwrite, whatever its caller is told.
  """

  defmodule Upsert do
    @moduledoc """
    phoenix_kit_ai's request cache: an unconditional upsert, refused only
    when the table is full and the key is not already in it. The insert
    follows the lookup only where it found the row.
    """
    use GenServer

    @table :races_exposure_upsert
    @max 1_000

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(@table, [:named_table, :public, :set])
      {:ok, state}
    end

    def put(key, value) do
      cond do
        :ets.info(@table, :size) >= @max and :ets.lookup(@table, key) == [] ->
          {:error, :full}

        true ->
          :ets.insert(@table, {key, value})
          :ok
      end
    end
  end

  defmodule Reserve do
    @moduledoc """
    The same comparison deciding a claim: the insert is on the side that
    found no row, and both racers are told they won.
    """
    use GenServer

    @table :races_exposure_reserve

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(@table, [:named_table, :public, :set])
      {:ok, state}
    end

    def reserve(key, owner) do
      cond do
        :ets.lookup(@table, key) == [] ->
          :ets.insert(@table, {key, owner})
          :ok

        true ->
          {:error, :taken}
      end
    end
  end

  defmodule TakeFree do
    @moduledoc """
    A write on the side that found the row, decided by what the row
    holds: both racers find the seat free and both take it. Not a claim
    of an absent row, and still a race.
    """
    use GenServer

    @table :races_exposure_seats

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(state) do
      :ets.new(@table, [:named_table, :public, :set])
      {:ok, state}
    end

    def take(seat, owner) do
      case :ets.lookup(@table, seat) do
        [{^seat, :free}] ->
          :ets.insert(@table, {seat, owner})
          :ok

        _ ->
          {:error, :taken}
      end
    end
  end

  defmodule MnesiaTakeFree do
    @moduledoc "TakeFree on a Mnesia record: both racers take the free seat."
    def take(seat, owner) do
      case :mnesia.dirty_read(:races_exposure_seats, seat) do
        [{:races_exposure_seats, ^seat, :free}] ->
          :mnesia.dirty_write({:races_exposure_seats, seat, owner})
          :ok

        _ ->
          {:error, :taken}
      end
    end
  end

  defmodule MnesiaRefresh do
    @moduledoc """
    A record rewritten only where the read found it, and its caller told
    whether it was: a refresh, not a claim.
    """
    def touch(user, at) do
      case :mnesia.dirty_read(:races_exposure_sessions, user) do
        [] ->
          {:error, :missing}

        [_found] ->
          :mnesia.dirty_write({:races_exposure_sessions, user, at})
          :ok
      end
    end
  end
end
