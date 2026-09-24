defmodule Argus.Priors.Driver do
  @moduledoc """
  Asks one question over one set of facts and returns its rows.

  Subjects sharing a batch key go into one request, at most `:batch_size`
  of them; each request is looked up in the cache first and asked of the
  oracle only in `:live` mode. An oracle error or a cache miss in
  `:cached_only` mode yields no rows for that request and is counted in
  the stats — a prior that could not be computed is an empty relation,
  never a failed analysis.

  Rows come back sorted and unique, so the same facts and the same
  answers give `==` rows: what every consumer that memoizes facts relies
  on.
  """

  require Logger

  alias Argus.Priors.Cache

  @type mode :: :cached_only | :live

  @type stats :: %{
          subjects: non_neg_integer(),
          requests: non_neg_integer(),
          cached: non_neg_integer(),
          asked: non_neg_integer(),
          failed: non_neg_integer(),
          input_tokens: non_neg_integer()
        }

  @default_batch 10
  @default_concurrency 16

  @doc """
  Rows of `question.relation()` for `facts`.

  ## Options

  - `:mode` — `:cached_only` or `:live` (required)
  - `:oracle` — an `Argus.Priors.Oracle` (default `Argus.Priors.Jev`)
  - `:oracle_opts` — passed to the oracle
  - `:model` — the model name in every request and cache key (default the
    Jev pin)
  - `:cache_dir` — default `Argus.Priors.Cache.root/0`; `:none` disables it
  - `:batch_size` — subjects per request (default #{@default_batch})
  - `:concurrency` — requests in flight (default #{@default_concurrency})
  """
  @spec derive(module(), Argus.Facts.t(), keyword()) :: {:ok, [[String.t()]], stats()}
  def derive(question, facts, opts) do
    {rows, stats} = derive_all([question], facts, opts)
    {:ok, Map.fetch!(rows, question), Map.fetch!(stats, question)}
  end

  @doc """
  `derive/3` for several questions at once, as
  `{%{question => rows}, %{question => stats}}`.

  Every question's requests share one pool of `:concurrency`: a run is
  as long as all its requests divided by the pool, not the sum of each
  question's rounds and tail. The questions' subjects are computed side
  by side, and a question's requests are asked as soon as its own
  subjects are ready, while a slower question is still being planned.
  Answers arrive in any order; rows are sorted, so that order never
  shows. Options are `derive/3`'s.
  """
  @spec derive_all([module()], Argus.Facts.t(), keyword()) ::
          {%{module() => [[String.t()]]}, %{module() => stats()}}
  def derive_all(questions, facts, opts) do
    mode = Keyword.fetch!(opts, :mode)
    model = Keyword.get(opts, :model, Argus.Priors.Jev.model())
    batch_size = Keyword.get(opts, :batch_size, @default_batch)

    # A plan is announced before its requests, so a question with none
    # still gets rows and stats.
    questions = Enum.uniq(questions)

    {plans, results} =
      questions
      |> Task.async_stream(&plan(&1, Map.take(facts, &1.relations_read()), model, batch_size),
        max_concurrency: max(length(questions), 1),
        timeout: :infinity,
        ordered: false
      )
      |> Stream.flat_map(fn {:ok, plan} ->
        [{:planned, plan} | Enum.map(plan.requests, &{:ask, plan, &1})]
      end)
      |> Task.async_stream(
        fn
          {:planned, plan} ->
            {:planned, plan}

          {:ask, plan, req} ->
            {:answered, plan.question, answer(req, plan.generation, mode, opts)}
        end,
        max_concurrency: Keyword.get(opts, :concurrency, @default_concurrency),
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce({%{}, %{}}, fn
        {:ok, {:planned, plan}}, {plans, results} ->
          {Map.put(plans, plan.question, plan), results}

        {:ok, {:answered, question, result}}, {plans, results} ->
          {plans, Map.update(results, question, [result], &[result | &1])}
      end)

    Enum.reduce(questions, {%{}, %{}}, fn question, {rows, stats} ->
      mine = Map.get(results, question, [])

      {Map.put(rows, question, rows(question, mine)),
       Map.put(stats, question, stats(plans[question].subjects, mine))}
    end)
  end

  defp plan(question, facts, model, batch_size) do
    generation = %{
      model: model,
      question: inspect(question),
      prompt_version: question.prompt_version()
    }

    subjects = question.subjects(facts)

    requests =
      subjects
      |> Enum.group_by(& &1.batch_key)
      |> Enum.sort_by(fn {key, _} -> inspect(key) end)
      |> Enum.flat_map(fn {_, group} -> Enum.chunk_every(group, batch_size) end)
      |> Enum.map(fn chunk ->
        request = %{
          model: model,
          state: question.state(chunk),
          questions: question.questions(chunk)
        }

        %{subjects: chunk, request: request, key: Cache.key(generation, request)}
      end)

    %{question: question, generation: generation, subjects: subjects, requests: requests}
  end

  defp rows(question, results) do
    results
    |> Enum.flat_map(fn
      {:ok, req, answers, _} -> question.rows(req.subjects, answers)
      {:error, _, _} -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp answer(req, generation, mode, opts) do
    cache_dir = Keyword.get(opts, :cache_dir, Cache.root())

    case lookup(cache_dir, generation, req.key) do
      {:ok, entry} ->
        {:ok, req, entry.response["answers"], :cached}

      :miss when mode == :cached_only ->
        {:error, req, :not_cached}

      :miss ->
        ask(req, generation, cache_dir, opts)
    end
  end

  defp lookup(:none, _generation, _key), do: :miss
  defp lookup(dir, generation, key), do: Cache.get(dir, generation, key)

  defp ask(req, generation, cache_dir, opts) do
    oracle = Keyword.get(opts, :oracle, Argus.Priors.Jev)

    case safe_ask(oracle, req.request, Keyword.get(opts, :oracle_opts, [])) do
      {:ok, response} ->
        store(cache_dir, generation, req.key, req.request, response)
        {:ok, req, response.answers, {:asked, Map.get(response.usage, "input_tokens", 0)}}

      {:error, reason} ->
        Logger.warning(
          "prior request failed (#{length(req.subjects)} subjects): #{inspect(reason)}"
        )

        {:error, req, reason}
    end
  end

  # An oracle that raises is an oracle that errored: the run goes on.
  defp safe_ask(oracle, request, oracle_opts) do
    oracle.ask(request, oracle_opts)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp store(:none, _generation, _key, _request, _response), do: :ok

  defp store(dir, generation, key, request, response) do
    case Cache.put(dir, generation, key, request, stringify(response)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("prior cache write failed: #{inspect(reason)}")
    end
  end

  # The cache stores JSON; a response read back has string keys, so one
  # written by the oracle is normalised before it goes in.
  defp stringify(response), do: response |> JSON.encode!() |> JSON.decode!()

  defp stats(subjects, results) do
    Enum.reduce(
      results,
      %{
        subjects: length(subjects),
        requests: length(results),
        cached: 0,
        asked: 0,
        failed: 0,
        input_tokens: 0
      },
      fn
        {:ok, _, _, :cached}, s ->
          %{s | cached: s.cached + 1}

        {:ok, _, _, {:asked, tokens}}, s ->
          %{s | asked: s.asked + 1, input_tokens: s.input_tokens + tokens}

        {:error, _, _}, s ->
          %{s | failed: s.failed + 1}
      end
    )
  end
end
