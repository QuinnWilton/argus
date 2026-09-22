defmodule Argus.Priors.Questions.SensitivityTest do
  use ExUnit.Case, async: true

  alias Argus.Priors.Questions.Sensitivity
  alias Argus.Test.Fixtures.Secret, as: S

  defp facts do
    {:ok, facts} =
      Argus.Pipeline.extract([S.Exposed, S.Heuristic, S.PartlyRedacted],
        format: :typed,
        extractors: [Argus.Extractors.EctoSchema]
      )

    facts
  end

  test "every field of every schema is a subject, batched by schema" do
    subjects = Sensitivity.subjects(facts())

    assert Enum.map(subjects, & &1.id) |> Enum.sort() ==
             Enum.sort([
               {inspect(S.Exposed), ":id"},
               {inspect(S.Exposed), ":name"},
               {inspect(S.Exposed), ":sendgrid_api_key"},
               {inspect(S.Exposed), ":smtp_password"},
               {inspect(S.Heuristic), ":id"},
               {inspect(S.Heuristic), ":totp_seed"},
               {inspect(S.Heuristic), ":label"},
               {inspect(S.PartlyRedacted), ":id"},
               {inspect(S.PartlyRedacted), ":api_key"},
               {inspect(S.PartlyRedacted), ":client_secret"}
             ])

    assert Enum.all?(subjects, &(&1.batch_key == &1.state.schema_module))
  end

  test "the shared state is the schema's whole field list, colons stripped" do
    subjects =
      facts()
      |> Sensitivity.subjects()
      |> Enum.filter(&(&1.batch_key == inspect(S.PartlyRedacted)))

    assert Sensitivity.state(subjects) == %{
             subject_kind: "schema_field",
             schema_module: inspect(S.PartlyRedacted),
             fields: ["api_key", "client_secret", "id"],
             redacted_fields: ["api_key"]
           }
  end

  test "the state holds names only" do
    for subject <- Sensitivity.subjects(facts()) do
      for {_k, v} <- subject.state, s <- List.wrap(v) do
        refute s =~ ~r/#\d+$/, "an instruction id leaked into the state: #{s}"
        refute s =~ ~r/\d{6,}/, "a long number leaked into the state: #{s}"
      end
    end
  end

  test "one choice and one noul per subject, suffixed by position" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    questions = Sensitivity.questions(subjects)

    assert Map.keys(questions) |> Enum.sort() ==
             ~w(kind__0 kind__1 kind__2 must_redact__0 must_redact__1 must_redact__2)

    assert questions["kind__1"].type == "choice"
    assert questions["kind__1"].instructions =~ "`label`"

    assert Map.keys(questions["kind__1"].criteria) |> Enum.sort() ==
             ~w(credential financial health none password pii token)a

    assert questions["must_redact__2"].type == "noul"
  end

  test "rows map the chosen kind to its class and probability to permille" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    answers = %{
      "kind__0" => %{"choice" => "none", "probabilities" => %{"none" => 0.99}},
      "kind__1" => %{"choice" => "none", "probabilities" => %{"none" => 0.8, "credential" => 0.2}},
      "kind__2" => %{"choice" => "credential", "probabilities" => %{"credential" => 0.9349}}
    }

    assert Sensitivity.rows(subjects, answers) == [
             ["schema_field", inspect(S.Heuristic), ":id", "none", "none", "990"],
             ["schema_field", inspect(S.Heuristic), ":label", "none", "none", "800"],
             ["schema_field", inspect(S.Heuristic), ":totp_seed", "secret", "credential", "935"]
           ]
  end

  test "a missing or unknown answer yields no row" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    answers = %{"kind__0" => %{"choice" => "banana", "probabilities" => %{}}}
    assert Sensitivity.rows(subjects, answers) == []
  end

  test "permille clamps and rounds" do
    assert Sensitivity.permille(0.9349) == 935
    assert Sensitivity.permille(1.2) == 1000
    assert Sensitivity.permille(-0.1) == 0
    assert Sensitivity.permille(1) == 1000
  end
end
