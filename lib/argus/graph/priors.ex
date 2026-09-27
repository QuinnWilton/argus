defmodule Argus.Graph.Priors do
  @moduledoc """
  The classifier's rows as the graph's `priors` input.

  Argus's layer-3 relations (`Argus.Priors`) are facts no extraction
  produces: a model's answers about names, with a probability. In the
  graph they are the `priors` input, one key per program and relation,
  set before the analyses are demanded — empty when priors are off, so
  every solve reads the file it expects and the findings are those of a
  run without priors.

  With priors on, the questions read the program's relations through
  the graph (`Argus.Graph.Relations.rows/3`), ask the model (or, in
  `:cached_only` mode, only the cache), and the rows go in as text: an
  unchanged answer sets an equal value and advances nothing, and a warm
  run repeats no request. A cassette named in the options is imported
  into the cache first, which is how a CI run without a key gets the
  answers a developer's run did.
  """

  alias Argus.Graph.Relations
  alias Argus.Priors.Cache
  alias Roux.Input

  require Logger

  @typedoc """
  `:off`, or the mode and `Argus.Priors` options (`cassette:` a JSONL
  file imported into the cache first, `cache_dir:`, `model:`, `oracle:`,
  `batch_size:`).
  """
  @type config :: :off | %{mode: :off | :cached_only | :live, opts: keyword()}

  @doc "Sets the `priors` input of every layer-3 relation of `program`."
  @spec sync(Roux.Database.t(), term(), config()) :: :ok
  def sync(db, program, :off), do: sync(db, program, %{mode: :off, opts: []})

  def sync(db, program, %{mode: :off}) do
    Enum.each(relations(), &(:ok = Input.set(db, :priors, {program, &1}, "")))
  end

  def sync(db, program, %{mode: mode, opts: opts}) do
    import_cassette(opts)

    facts =
      Argus.Priors.relations_read()
      |> Map.new(&{&1, Relations.rows(db, program, &1)})
      |> Argus.Facts.decode()

    {rows, stats} =
      Argus.Priors.rows(facts, opts |> Keyword.drop([:cassette]) |> Keyword.put(:mode, mode))

    Enum.each(stats, fn {question, s} ->
      Logger.debug(
        "argus priors #{inspect(question)}: #{s.subjects} subjects, #{s.requests} requests, " <>
          "#{s.cached} cached, #{s.asked} asked, #{s.failed} failed"
      )
    end)

    Enum.each(relations(), fn relation ->
      text = rows |> Map.get(relation, []) |> Argus.Tsv.encode() |> IO.iodata_to_binary()
      :ok = Input.set(db, :priors, {program, relation}, text)
    end)
  end

  @doc "The layer-3 relations, as `Argus.Schema` declares them."
  @spec relations() :: [atom()]
  def relations, do: Enum.map(Argus.Schema.layer_3(), & &1.name)

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
            Logger.warning("argus priors: cassette #{path} not read: #{inspect(reason)}")
        end
    end
  end
end
