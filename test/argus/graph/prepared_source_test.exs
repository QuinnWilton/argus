defmodule Argus.Graph.PreparedSourceTest do
  use ExUnit.Case, async: true

  alias Argus.Graph.Prepared
  alias Argus.Specs.Source
  alias Roux.{Database, Dependencies, Input, Memo, Revision}

  test "source reuse follows replacement, deletion, database scope and same-revision writes" do
    db = Database.new()
    other = Database.new()
    on_exit(fn -> Enum.each([db, other], &stop/1) end)
    for database <- [db, other], do: Database.register_input(database, :specs_source)
    first = %Source{index: %{"one" => "one.beam"}}
    second = %Source{index: %{"two" => "two.beam"}}

    assert Prepared.source(db) == nil
    Input.set(db, :specs_source, :all, first)
    assert Prepared.source(db) == first
    Input.set(db, :specs_source, :all, second)
    assert Prepared.source(db) == second
    assert Prepared.source(other) == nil
    assert Prepared.source(db) == second

    {:ok, entry} = Memo.get(db, {:input, :specs_source, :all})
    revision = Revision.current(db.revision)
    Memo.put(db, {:input, :specs_source, :all}, %{entry | value: first})
    assert Revision.current(db.revision) == revision
    assert Prepared.source(db) == first

    Dependencies.mutate(db, {:input, :specs_source, :all}, fn ->
      Input.set(db, :specs_source, :all, second)
      assert Prepared.source(db) == second
    end)

    Input.delete(db, :specs_source, :all)
    assert Prepared.source(db) == nil
  end

  defp stop(db) do
    Database.shutdown(db)
  catch
    :exit, _ -> :ok
  end
end
