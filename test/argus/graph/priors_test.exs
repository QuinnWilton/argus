defmodule Argus.Graph.PriorsTest do
  @moduledoc """
  A prior relation is the `:prior_rows` input, and a consumer that demands
  the graph without setting it — planchette's LSP, encore's adapters —
  gets the empty relation, not an error.
  """

  use ExUnit.Case, async: true

  alias Roux.{Database, Input}

  # The database is linked to the test process and goes with it; an
  # on_exit shutdown would run after it is already gone.
  setup do
    db = Database.new()
    :ok = Roux.Lang.register_module(db, Argus.Graph.Frontend)
    :ok = Roux.Lang.register_module(db, Argus.Graph)
    %{db: db}
  end

  test "the layer-3 relations are the prior relations" do
    assert Argus.Graph.prior_relations() == Enum.map(Argus.Schema.layer_3(), & &1.name)
    assert :prior_sensitive in Argus.Graph.prior_relations()
  end

  test "unset, a prior relation reads as empty; set later, the read follows", %{db: db} do
    assert Argus.Graph.relation_rows(db, :prior_sensitive) == []

    :ok = Input.set(db, :prior_rows, :prior_sensitive, [{1, 2, 3, 4, 5, 950}])
    assert Argus.Graph.relation_rows(db, :prior_sensitive) == [{1, 2, 3, 4, 5, 950}]

    :ok = Input.set(db, :prior_rows, :prior_sensitive, [])
    assert Argus.Graph.relation_rows(db, :prior_sensitive) == []
  end
end
