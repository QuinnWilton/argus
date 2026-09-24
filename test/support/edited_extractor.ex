defmodule Scry.Test.EditedExtractor do
  @moduledoc """
  A stand-in for an argus extractor someone edits: the rows of
  `Argus.Extractors.GenStatem`, less its `statem_*` relations once
  `edit!/0` has run in this VM. A graph joined from it in place of the
  real one sees what an edit to that extractor does — its producer's
  digest moves (the test moves it) and its rows change for the modules
  that define a state machine, read by `:mailbox` and not by
  `:coupling`.
  """

  @behaviour Argus.Extractor

  alias Argus.Extractors.GenStatem

  @impl true
  def relations, do: GenStatem.relations()

  @impl true
  def extract(data) do
    facts = GenStatem.extract(data)

    if :persistent_term.get({__MODULE__, :edited}, false),
      do: Map.reject(facts, fn {relation, _rows} -> statem?(relation) end),
      else: facts
  end

  @doc "Whether a relation is one `edit!/0` drops."
  @spec statem?(atom()) :: boolean()
  def statem?(relation), do: String.starts_with?(Atom.to_string(relation), "statem_")

  @doc "Edits the extractor, in this VM, until `revert!/0`."
  @spec edit!() :: :ok
  def edit!, do: :persistent_term.put({__MODULE__, :edited}, true)

  @doc "Undoes `edit!/0`."
  @spec revert!() :: :ok
  def revert! do
    _ = :persistent_term.erase({__MODULE__, :edited})
    :ok
  end
end
