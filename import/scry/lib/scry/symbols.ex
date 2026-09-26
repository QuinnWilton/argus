defmodule Scry.Symbols do
  @moduledoc """
  The `Argus.Symbols` table scry interns fact rows against: an
  `Argus.Symbols.Store` over one of the database's `Roux.Intern` tables,
  so the ids memoized rows carry are persisted in the manifest with them
  and mean the same thing on the next run.

  One `Argus.Symbols` struct per database per process — the struct
  carries a parse cache that must be created once, not per query.
  """

  @behaviour Argus.Symbols.Store

  alias Roux.{Database, Intern}

  @intern_table :argus_symbols

  @doc "The symbols table for `db`, created on first use by this process."
  @spec for_db(Database.t()) :: Argus.Symbols.t()
  def for_db(%Database{memo_table: table} = db) do
    key = {__MODULE__, table}

    case Process.get(key) do
      %Argus.Symbols{} = symbols ->
        symbols

      nil ->
        symbols = Argus.Symbols.new(__MODULE__, Database.intern_table(db, @intern_table))
        Process.put(key, symbols)
        symbols
    end
  end

  @impl true
  def intern(%Intern{} = intern, binary), do: Intern.intern(intern, binary)

  @impl true
  def resolve(%Intern{} = intern, id), do: Intern.resolve!(intern, id)
end
