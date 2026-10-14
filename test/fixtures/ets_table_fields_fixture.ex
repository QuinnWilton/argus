defmodule Argus.Test.Fixtures.EtsTableFields do
  @moduledoc """
  Fixtures for ETS tables one `:ets.new/2` site makes, one per element of a
  collection, and keeps under different fields of one struct: roux's
  `Database`, whose tables a single closure makes in `Map.new/2`
  (`races.ets_check_act`).

  Each module makes its own tables, so that every set solves alone. The
  site is one points-to object for all of them; the field each operation
  reads the table from tells the tables apart.
  """

  defmodule OtherField do
    @moduledoc """
    A lookup of the claims table decides an insert into the owners table:
    the same key, but another table (roux's `wait_for_claimant/2`, whose
    lookup of `dedup_table` decides an insert into `dedup_waiters`).
    """
    defstruct [:claims, :owners]

    def new do
      tables =
        Map.new([claims: :set, owners: :set], fn {name, type} ->
          {name, :ets.new(name, [type, :public])}
        end)

      %__MODULE__{claims: tables.claims, owners: tables.owners}
    end

    def run(key) do
      db = new()
      spawn(fn -> note(db, key) end)
      note(db, key)
    end

    def note(db, key) do
      case :ets.lookup(db.claims, key) do
        [] ->
          :ets.insert(db.owners, {key, self()})
          :won

        _found ->
          :lost
      end
    end
  end

  defmodule SameField do
    @moduledoc """
    The same claim made in the claims table it read: a lookup that found
    no row decides an insert of the row, and both callers can be told they
    won.
    """
    defstruct [:claims, :owners]

    def new do
      tables =
        Map.new([claims: :set, owners: :set], fn {name, type} ->
          {name, :ets.new(name, [type, :public])}
        end)

      %__MODULE__{claims: tables.claims, owners: tables.owners}
    end

    def run(key) do
      db = new()
      spawn(fn -> claim(db, key) end)
      owner(db, key)
      claim(db, key)
    end

    def claim(db, key) do
      case :ets.lookup(db.claims, key) do
        [] ->
          :ets.insert(db.claims, {key, self()})
          :won

        _found ->
          :lost
      end
    end

    def owner(db, key), do: :ets.lookup(db.owners, key)
  end

  defmodule UnfieldedTable do
    @moduledoc """
    The insert's table is a helper's answer, which no field names: it can
    be any of the site's tables, the claims table included, and the claim
    is still reported.
    """
    defstruct [:claims, :owners]

    def new do
      tables =
        Map.new([claims: :set, owners: :set], fn {name, type} ->
          {name, :ets.new(name, [type, :public])}
        end)

      %__MODULE__{claims: tables.claims, owners: tables.owners}
    end

    def run(key) do
      db = new()
      spawn(fn -> claim(db, key) end)
      owner(db, key)
      claim(db, key)
    end

    def claim(db, key) do
      case :ets.lookup(db.claims, key) do
        [] ->
          :ets.insert(table_of(db), {key, self()})
          :won

        _found ->
          :lost
      end
    end

    def owner(db, key), do: :ets.lookup(db.owners, key)

    defp table_of(db), do: Map.fetch!(db, :claims)
  end
end
