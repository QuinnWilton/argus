defmodule Argus.Priors.RowsTest do
  @moduledoc """
  `Argus.Priors.rows/2`: every question's rows from facts already in hand,
  the entry point a consumer with its own fact store (scry) uses.
  """

  use ExUnit.Case, async: true

  alias Argus.Priors
  alias Argus.Test.Fixtures.Secret, as: S

  @moduletag :tmp_dir

  defmodule Oracle do
    @behaviour Argus.Priors.Oracle

    @impl true
    def ask(request, _opts) do
      answers =
        for {id, q} <- request.questions, into: %{} do
          case q.type do
            "choice" ->
              first = q.criteria |> Map.keys() |> Enum.sort() |> List.first() |> to_string()

              {id,
               %{
                 "type" => "choice",
                 "choice" => first,
                 "confidence" => 0.6,
                 "probabilities" => %{first => 0.6}
               }}

            "noul" ->
              {id, %{"type" => "noul", "noul" => 0.2}}
          end
        end

      {:ok,
       %{answers: answers, usage: %{"input_tokens" => 5}, model: request.model, request_id: nil}}
    end
  end

  test "relations_read is the union over the built-in questions" do
    read = Priors.relations_read()
    assert :schema_field in read and :redacted_field in read
    assert :function_def in read and :remote_call in read
    assert read == Enum.uniq(read)
  end

  test "rows maps every question's relation, empty or not, from typed facts", %{tmp_dir: dir} do
    {:ok, facts} =
      Argus.Pipeline.extract([S.Exposed],
        format: :typed,
        extractors: [Argus.Extractors.EctoSchema]
      )

    facts = Map.merge(Map.new(Priors.relations_read(), &{&1, []}), facts)

    {rows, stats} =
      Priors.rows(facts, mode: :live, oracle: Oracle, cache_dir: dir, model: "jev-test")

    assert Map.keys(rows) |> Enum.sort() ==
             Enum.sort(Enum.map(Priors.questions(), & &1.relation()))

    assert rows[:prior_reads] == [] and rows[:prior_talks_to_process] == []

    assert rows[:prior_sensitive] ==
             for(
               field <- ~w(:id :name :sendgrid_api_key :smtp_password),
               do: [
                 "schema_field",
                 inspect(S.Exposed),
                 field,
                 "secret",
                 "credential",
                 "600",
                 "600"
               ]
             )

    assert stats[Argus.Priors.Questions.Sensitivity].asked == 1
    assert stats[Argus.Priors.Questions.Reads].subjects == 0
  end
end
