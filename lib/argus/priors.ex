defmodule Argus.Priors do
  @moduledoc """
  Heuristic facts: a classifier's answers to the questions bytecode cannot
  settle, as layer-3 relations.

  Some judgements an analysis needs are ones a reader makes from names —
  whether `totp_seed` is a secret, whether a module fronts a process,
  what a helper reads, whether the string a library makes an atom of is
  a pool's name or a URL's scheme. `Argus.Priors` asks those of a System-One model
  (typesafe.ai's Jev, through `Argus.Priors.Jev`) and writes the answers
  into the facts directory as `prior_*` relations, each row with the
  model's probability in thousandths. Rules read them as a positive
  premise only: a prior can add a finding marked heuristic or move a
  severity, never remove a structural row, so a run with priors reports
  everything a run without them does.

  ## Modes

  Off by default: nothing is asked and every prior relation is empty. In
  `:cached_only` mode answers come from `Argus.Priors.Cache` alone — a
  cassette imported with `mix argus.priors import` makes such a run
  deterministic and offline. In `:live` mode misses are asked of the
  oracle, which needs `TYPESAFE_API_KEY` (or an `:oracle` of your own).

      Argus.run_analyses(mods, analyses: [:exposure], priors: :live)
      Argus.run_analyses(mods, analyses: [:exposure], priors: :cached_only)

  The other options (`:oracle`, `:oracle_opts`, `:model`, `:cache_dir`,
  `:batch_size`, `:concurrency`) are `Argus.Priors.Driver.derive/3`'s,
  passed under `:priors_opts`.

  ## Questions

  Each `Argus.Priors.Question` fills one relation from the residue of one
  judgement. `questions/0` lists the built-in ones; the calibration that
  admitted each is in the module's own docs.
  """

  require Logger

  alias Argus.Priors.{Driver, Jev}

  @type mode :: :off | :cached_only | :live

  @questions [
    Argus.Priors.Questions.PeerAnswers,
    Argus.Priors.Questions.ProcessRole,
    Argus.Priors.Questions.Reads,
    Argus.Priors.Questions.Sensitivity,
    Argus.Priors.Questions.Tooling,
    Argus.Priors.Questions.ValueSource
  ]

  @doc "The built-in questions."
  @spec questions() :: [module()]
  def questions, do: @questions

  @doc """
  Checks the priors options before any extraction, so a run that cannot
  ask fails at once rather than after the work is done.
  """
  @spec check!(keyword()) :: :ok
  def check!(opts) do
    priors_opts = Keyword.get(opts, :priors_opts, [])

    case Keyword.get(opts, :priors, :off) do
      :off ->
        :ok

      :cached_only ->
        :ok

      :live ->
        oracle = Keyword.get(priors_opts, :oracle, Jev)

        if oracle == Jev and Jev.api_key(Keyword.get(priors_opts, :oracle_opts, [])) == :error do
          raise ArgumentError,
                "priors: :live asks #{inspect(oracle)}, which needs #{Jev.env_var()} " <>
                  "in the environment (or :api_key under :priors_opts' :oracle_opts); " <>
                  "use priors: :cached_only for answers already in the cache"
        end

        :ok

      other ->
        raise ArgumentError, "priors: expected :off, :cached_only or :live, got #{inspect(other)}"
    end
  end

  @doc """
  Derives every question's rows from the facts in `facts_dir` and writes
  them there as `<relation>.facts`, replacing the empty files the
  pipeline touched. Returns the stats per question.
  """
  @spec derive(Path.t(), keyword()) :: {:ok, %{module() => Driver.stats()}} | {:error, term()}
  def derive(facts_dir, opts) do
    questions = Keyword.get(opts, :questions, @questions)

    with {:ok, facts} <- read_facts(facts_dir, relations_read(questions)) do
      {rows, stats} = rows(facts, opts)

      Enum.each(rows, fn {relation, relation_rows} ->
        write_rows!(facts_dir, relation, relation_rows)
      end)

      {:ok, stats}
    end
  end

  @doc """
  The relations every question in `questions` (default: the built-in
  ones) reads — what a caller deriving from its own facts must supply.
  """
  @spec relations_read([module()]) :: [atom()]
  def relations_read(questions \\ @questions) do
    questions |> Enum.flat_map(& &1.relations_read()) |> Enum.uniq()
  end

  @doc """
  Every question's rows from typed facts already in hand — the shape
  `Argus.Pipeline.extract/2` returns with `format: :typed`, holding at
  least `relations_read/1` — as `{%{relation => rows}, %{question => stats}}`.
  A question that yields nothing still maps to `[]`, so a consumer can
  set every prior relation, empty or not. Options are `derive/2`'s.
  """
  @spec rows(Argus.Facts.t(), keyword()) ::
          {%{atom() => [[String.t()]]}, %{module() => Driver.stats()}}
  def rows(facts, opts) do
    questions = Keyword.get(opts, :questions, @questions)
    {rows, stats} = Driver.derive_all(questions, facts, opts)

    {Map.new(rows, fn {question, relation_rows} -> {question.relation(), relation_rows} end),
     stats}
  end

  @doc """
  Typed rows of `relations` from a facts directory, the shape
  `Argus.Pipeline.extract/2` returns with `format: :typed`.
  """
  @spec read_facts(Path.t(), [atom()]) :: {:ok, Argus.Facts.t()} | {:error, term()}
  def read_facts(facts_dir, relations) do
    Enum.reduce_while(relations, {:ok, %{}}, fn relation, {:ok, acc} ->
      path = Path.join(facts_dir, "#{relation}.facts")

      case File.read(path) do
        {:ok, content} ->
          {:cont, {:ok, Map.put(acc, relation, Argus.Tsv.decode(content))}}

        {:error, reason} ->
          {:halt, {:error, {:read_failed, path, reason}}}
      end
    end)
    |> case do
      {:ok, raw} -> {:ok, Argus.Facts.decode(raw)}
      error -> error
    end
  end

  defp write_rows!(facts_dir, relation, rows) do
    File.write!(Path.join(facts_dir, "#{relation}.facts"), Argus.Tsv.encode(rows))
  end
end
