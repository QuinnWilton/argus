defmodule Scry.Priors do
  @moduledoc """
  The classifier's rows as roux inputs.

  Argus's layer-3 relations (`Argus.Priors`) are facts no extraction
  produces: a model's answers about names, with a probability. In scry
  they are the `:prior_rows` input, one key per relation, set here on
  every run before the analyses are demanded — `[]` when priors are off,
  so the projections always find the file they expect and the findings
  are those of a run without priors.

  With priors on, the questions read the program's relations through the
  same memoized queries the projections use, ask the model (or, in
  `:cached_only` mode, only the cache) and the rows go in as an input:
  `Input.set`'s equality cutoff means an unchanged answer advances
  nothing, and `:medium` durability keeps the rows in the manifest, so a
  warm run re-solves nothing and repeats no request. A cassette named in
  the config is imported into the cache first, which is how a CI run
  without a key gets the same answers a developer's run did.
  """

  alias Argus.Facts
  alias Argus.Priors.Cache
  alias Roux.Input
  alias Scry.Symbols

  require Logger

  @doc """
  Sets `:prior_rows` for every layer-3 relation from `config.priors`.
  """
  @spec sync(Roux.Database.t(), Scry.Config.t()) :: :ok
  def sync(db, %Scry.Config{priors: %{mode: :off}}) do
    Enum.each(Scry.Analysis.prior_relations(), &(:ok = Input.set(db, :prior_rows, &1, [])))
  end

  def sync(db, %Scry.Config{priors: %{mode: mode, opts: opts}}) do
    import_cassette(opts)
    facts = program_facts(db)

    {rows, stats} =
      Argus.Priors.rows(facts, opts |> Keyword.drop([:cassette]) |> Keyword.put(:mode, mode))

    Enum.each(stats, fn {question, s} ->
      Logger.debug(
        "scry priors #{inspect(question)}: #{s.subjects} subjects, #{s.requests} requests, " <>
          "#{s.cached} cached, #{s.asked} asked, #{s.failed} failed"
      )
    end)

    interned = Facts.intern(rows, Symbols.for_db(db))

    Enum.each(Scry.Analysis.prior_relations(), fn relation ->
      :ok = Input.set(db, :prior_rows, relation, Map.get(interned, relation, []))
    end)
  end

  # The relations the questions read, as typed facts: the memoized string
  # rows of each, decoded against the schema.
  defp program_facts(db) do
    Argus.Priors.relations_read()
    |> Map.new(fn relation -> {relation, Scry.Analysis.relation_facts(db, relation)} end)
    |> Facts.decode()
  end

  defp import_cassette(opts) do
    case Keyword.get(opts, :cassette) do
      nil ->
        :ok

      path ->
        dir = Keyword.get(opts, :cache_dir, Cache.root())

        case Cache.import(dir, path) do
          {:ok, _n} ->
            :ok

          {:error, reason} ->
            Logger.warning("scry priors: cassette #{path} not read: #{inspect(reason)}")
        end
    end
  end
end
