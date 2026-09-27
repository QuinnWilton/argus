defmodule Argus.Graph.PriorsTest do
  @moduledoc """
  A prior relation is the `priors` input's text, and a consumer that
  demands the graph without setting it gets the empty relation, not an
  error: the meaning of priors off.
  """

  use ExUnit.Case, async: true

  alias Argus.Graph.{Priors, Relations}
  alias Argus.Test.Graph
  alias Roux.Input

  test "the layer-3 relations are the prior relations" do
    assert Priors.relations() == Enum.map(Argus.Schema.layer_3(), & &1.name)
    assert :prior_sensitive in Priors.relations()
  end

  test "unset, a prior relation reads as empty; set later, the read follows" do
    db = Graph.new_db(%{}, program: :unset)
    Enum.each(Priors.relations(), &Input.delete(db, :priors, {:unset, &1}))

    assert Relations.rows(db, :unset, :prior_sensitive) == []

    row = ["Mod:f/1", "sensitive", "name", "0", "x", "950"]

    :ok =
      Input.set(
        db,
        :priors,
        {:unset, :prior_sensitive},
        IO.iodata_to_binary(Argus.Tsv.encode([row]))
      )

    assert Relations.rows(db, :unset, :prior_sensitive) == [row]

    :ok = Priors.sync(db, :unset, :off)
    assert Relations.rows(db, :unset, :prior_sensitive) == []
  end
end
