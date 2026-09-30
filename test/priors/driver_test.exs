defmodule Argus.Priors.DriverTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.{Cache, Driver}
  alias Argus.Priors.Questions.Sensitivity

  @moduletag :tmp_dir

  # Answers every kind question from a table of field names; anything not
  # in the table is `none`. Records each request in the test process.
  defmodule TableOracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, opts) do
      send(Keyword.fetch!(opts, :notify), {:asked, request})
      table = Keyword.get(opts, :table, %{})

      answers =
        for {id, %{type: "choice"}} <- request.questions, into: %{} do
          idx = id |> String.split("__") |> List.last() |> String.to_integer()
          field = request.state.fields_asked |> Enum.at(idx)
          {detail, p} = Map.get(table, field, {"none", 0.97})

          {id,
           %{
             "type" => "choice",
             "choice" => detail,
             "confidence" => p,
             "probabilities" => %{detail => p}
           }}
        end

      {:ok,
       %{
         answers: answers,
         usage: %{"input_tokens" => 100},
         model: request.model,
         request_id: "req_test"
       }}
    end
  end

  # A question whose state lists the asked fields in order, so the oracle
  # can answer by name.
  defmodule Question do
    @behaviour Argus.Priors.Question

    @impl true
    def relation, do: :prior_sensitive
    @impl true
    def prompt_version, do: 7
    @impl true
    def relations_read, do: [:schema_field, :redacted_field]
    @impl true
    def subjects(facts), do: Sensitivity.subjects(facts)

    @impl true
    def state(subjects),
      do:
        subjects
        |> Sensitivity.state()
        |> Map.put(:fields_asked, Enum.map(subjects, & &1.state.field))

    @impl true
    def questions(subjects), do: Sensitivity.questions(subjects)
    @impl true
    def rows(subjects, answers), do: Sensitivity.rows(subjects, answers)
  end

  @facts %{
    schema_field: [
      %{mod: "A", field: ":id"},
      %{mod: "A", field: ":totp_seed"},
      %{mod: "A", field: ":label"},
      %{mod: "B", field: ":email"}
    ],
    redacted_field: []
  }

  defp opts(dir, extra \\ []) do
    Keyword.merge(
      [
        mode: :live,
        oracle: TableOracle,
        oracle_opts: [
          notify: self(),
          table: %{"totp_seed" => {"credential", 0.95}, "email" => {"pii", 0.9}}
        ],
        cache_dir: dir,
        model: "jev-test"
      ],
      extra
    )
  end

  test "one request per schema, rows sorted, permille from the probability", %{tmp_dir: dir} do
    assert {:ok, rows, stats} = Driver.derive(Question, @facts, opts(dir))

    assert rows == [
             ["schema_field", "A", ":id", "none", "none", "970", "970"],
             ["schema_field", "A", ":label", "none", "none", "970", "970"],
             ["schema_field", "A", ":totp_seed", "secret", "credential", "950", "950"],
             ["schema_field", "B", ":email", "personal", "pii", "900", "900"]
           ]

    assert stats == %{subjects: 4, requests: 2, cached: 0, asked: 2, failed: 0, input_tokens: 200}

    assert_receive {:asked,
                    %{state: %{schema_module: "A", fields_asked: ["id", "label", "totp_seed"]}}}

    assert_receive {:asked, %{state: %{schema_module: "B"}}}
  end

  test "batch_size splits a schema into several requests", %{tmp_dir: dir} do
    assert {:ok, rows, stats} = Driver.derive(Question, @facts, opts(dir, batch_size: 2))
    assert length(rows) == 4
    assert stats.requests == 3
  end

  test "a second run is served from the cache and asks nothing", %{tmp_dir: dir} do
    {:ok, rows, _} = Driver.derive(Question, @facts, opts(dir))
    flush()

    assert {:ok, ^rows, stats} = Driver.derive(Question, @facts, opts(dir))
    assert stats.cached == 2 and stats.asked == 0
    refute_receive {:asked, _}
  end

  test "cached_only yields no rows for a miss and counts it", %{tmp_dir: dir} do
    assert {:ok, [], stats} = Driver.derive(Question, @facts, opts(dir, mode: :cached_only))
    assert stats.failed == 2
    refute_receive {:asked, _}

    {:ok, _, _} = Driver.derive(Question, @facts, opts(dir))
    flush()

    assert {:ok, rows, %{cached: 2, failed: 0}} =
             Driver.derive(Question, @facts, opts(dir, mode: :cached_only))

    assert length(rows) == 4
  end

  @tag :capture_log
  test "an oracle error or raise loses that request only", %{tmp_dir: dir} do
    defmodule Flaky do
      @behaviour Argus.Priors.Oracle
      @impl true
      def ask(%{state: %{schema_module: "A"}}, _), do: raise("boom")
      def ask(request, opts), do: TableOracle.ask(request, opts)
    end

    assert {:ok, rows, stats} = Driver.derive(Question, @facts, opts(dir, oracle: Flaky))
    assert [["schema_field", "B", ":email", "personal", "pii", "900", "900"]] = rows
    assert stats.failed == 1 and stats.asked == 1
    assert Cache.entries(dir) |> Map.values() |> List.flatten() |> length() == 1
  end

  test "the cache key carries the model and the question's prompt version", %{tmp_dir: dir} do
    {:ok, _, _} = Driver.derive(Question, @facts, opts(dir))
    assert %{"jev-test--Question--v7" => entries} = Cache.entries(dir)
    assert length(entries) == 2
  end

  # Holds each request until `:gate` are in flight at once (or a second
  # has passed), recording the most it saw: a pool that asked one at a
  # time would see 1 and wait out every gate.
  defmodule GateOracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, opts) do
      counter = Keyword.fetch!(opts, :counter)
      n = :atomics.add_get(counter, 1, 1)
      :atomics.put(counter, 2, max(n, :atomics.get(counter, 2)))
      wait_for(counter, Keyword.fetch!(opts, :gate), System.monotonic_time(:millisecond) + 1_000)
      result = TableOracle.ask(request, opts)
      :atomics.sub(counter, 1, 1)
      result
    end

    defp wait_for(counter, gate, deadline) do
      cond do
        :atomics.get(counter, 2) >= gate ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          :timeout

        true ->
          Process.sleep(5)
          wait_for(counter, gate, deadline)
      end
    end
  end

  # The same question under another name, so two questions share a run.
  defmodule OtherQuestion do
    @behaviour Argus.Priors.Question

    @impl true
    def relation, do: :prior_other
    @impl true
    def prompt_version, do: 1
    @impl true
    defdelegate relations_read, to: Question
    @impl true
    defdelegate subjects(facts), to: Question
    @impl true
    defdelegate state(subjects), to: Question
    @impl true
    defdelegate questions(subjects), to: Question
    @impl true
    defdelegate rows(subjects, answers), to: Question
  end

  test "every question's requests are in flight together, up to the concurrency",
       %{tmp_dir: dir} do
    counter = :atomics.new(2, [])

    # Batches of one: 4 requests per question, 8 in all, 6 at a time.
    {rows, stats} =
      Driver.derive_all(
        [Question, OtherQuestion],
        @facts,
        opts(dir,
          oracle: GateOracle,
          oracle_opts: [notify: self(), counter: counter, gate: 6],
          batch_size: 1,
          concurrency: 6
        )
      )

    # More than one question's four requests were in flight at once.
    assert :atomics.get(counter, 2) == 6
    assert length(rows[Question]) == 4 and rows[Question] == rows[OtherQuestion]
    assert stats[Question].asked == 4 and stats[OtherQuestion].asked == 4
  end

  test "derive_all gives each question derive/3's rows and stats", %{tmp_dir: dir} do
    {:ok, rows, stats} = Driver.derive(Question, @facts, opts(dir, cache_dir: :none))

    assert {%{Question => ^rows, OtherQuestion => ^rows},
            %{Question => ^stats, OtherQuestion => ^stats}} =
             Driver.derive_all(
               [Question, OtherQuestion],
               @facts,
               opts(dir, cache_dir: :none)
             )
  end

  defp flush do
    receive do
      {:asked, _} -> flush()
    after
      0 -> :ok
    end
  end
end
