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

    # No __schema__/2 here, so no types: a field is its name alone.
    assert Sensitivity.state(subjects) == %{
             subject_kind: "schema_field",
             schema_module: inspect(S.PartlyRedacted),
             fields: [%{name: "api_key"}, %{name: "client_secret"}, %{name: "id"}],
             redacted_fields: ["api_key"]
           }
  end

  test "each field is shown with its type when the schema says one" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    assert Sensitivity.state(subjects).fields == [
             %{name: "id", type: "id"},
             %{name: "label", type: "string"},
             %{name: "totp_seed", type: "Argus.Test.Encrypted.Binary"}
           ]
  end

  test "a type the extractor could not read is left out, not shown as dynamic" do
    facts = %{
      schema_field: [
        %{mod: "A", field: ":key", type: "dynamic"},
        %{mod: "A", field: ":name", type: "string"}
      ],
      redacted_field: []
    }

    assert [%{state: %{fields: [%{name: "key"}, %{name: "name", type: "string"}]}} | _] =
             Sensitivity.subjects(facts)
  end

  test "the state holds names only" do
    for subject <- Sensitivity.subjects(facts()), {_k, v} <- subject.state, s <- strings(v) do
      refute s =~ ~r/#\d+$/, "an instruction id leaked into the state: #{s}"
      refute s =~ ~r/\d{6,}/, "a long number leaked into the state: #{s}"
    end
  end

  defp strings(v) when is_binary(v), do: [v]
  defp strings(v) when is_map(v), do: v |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(v) when is_list(v), do: Enum.flat_map(v, &strings/1)
  defp strings(_), do: []

  test "one choice per subject, suffixed by position, with somewhere for a secret's name to go" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    questions = Sensitivity.questions(subjects)

    assert Map.keys(questions) |> Enum.sort() == ~w(kind__0 kind__1 kind__2)

    assert questions["kind__1"].type == "choice"
    assert questions["kind__1"].instructions =~ "`label`"
    assert questions["kind__1"].instructions =~ "its type"

    assert Map.keys(questions["kind__1"].criteria) |> Enum.sort() ==
             ~w(credential financial health none password pii public_key secret_reference token)a
  end

  test "the prompt version is part of every cache key: v2 asks afresh" do
    assert Sensitivity.prompt_version() == 2
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
             ["schema_field", inspect(S.Heuristic), ":id", "none", "none", "990", "990"],
             ["schema_field", inspect(S.Heuristic), ":label", "none", "none", "800", "800"],
             [
               "schema_field",
               inspect(S.Heuristic),
               ":totp_seed",
               "secret",
               "credential",
               "935",
               "935"
             ]
           ]
  end

  test "a secret split across kinds is a secret at the sum, reported by its likeliest kind" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    # sequin's NatsSink.jwt, as Jev answered it: sure it is a secret,
    # unsure whether a token or a credential. The chosen kind alone is
    # 0.89, under exposure's 0.9; the class is 1.00.
    answers = %{
      "kind__0" => %{
        "choice" => "none",
        "probabilities" => %{"none" => 0.4, "token" => 0.3, "credential" => 0.3}
      },
      "kind__2" => %{
        "choice" => "token",
        "probabilities" => %{"token" => 0.89, "credential" => 0.11, "none" => 0.0}
      }
    }

    assert Sensitivity.rows(subjects, answers) == [
             # The rest outweigh the choice: a secret at 0.6, and of two
             # equal kinds, the first by name.
             ["schema_field", inspect(S.Heuristic), ":id", "secret", "credential", "300", "600"],
             [
               "schema_field",
               inspect(S.Heuristic),
               ":totp_seed",
               "secret",
               "token",
               "890",
               "1000"
             ]
           ]
  end

  test "a tie between classes goes to the chosen kind's" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    answers = %{
      "kind__0" => %{"choice" => "pii", "probabilities" => %{"pii" => 0.5, "token" => 0.5}}
    }

    assert [["schema_field", _, ":id", "personal", "pii", "500", "500"]] =
             Sensitivity.rows(subjects, answers)
  end

  test "a missing or unknown answer yields no row" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    answers = %{"kind__0" => %{"choice" => "banana", "probabilities" => %{}}}
    assert Sensitivity.rows(subjects, answers) == []
  end

  test "a secret's reference or public half is `none`, and its mass counts against a secret" do
    subjects =
      facts() |> Sensitivity.subjects() |> Enum.filter(&(&1.batch_key == inspect(S.Heuristic)))

    # nerves_hub's SharedSecretAuth.key beside its `secret`, and an
    # Ed25519 public key: version 1 had nowhere to put either but
    # `credential`.
    answers = %{
      "kind__0" => %{
        "choice" => "secret_reference",
        "probabilities" => %{"secret_reference" => 0.74, "credential" => 0.26}
      },
      "kind__1" => %{
        "choice" => "credential",
        "probabilities" => %{"credential" => 0.55, "public_key" => 0.3, "none" => 0.15}
      },
      "kind__2" => %{
        "choice" => "credential",
        "probabilities" => %{"credential" => 0.83, "public_key" => 0.17}
      }
    }

    assert Sensitivity.rows(subjects, answers) == [
             [
               "schema_field",
               inspect(S.Heuristic),
               ":id",
               "none",
               "secret_reference",
               "740",
               "740"
             ],
             # 0.55 against 0.45 for none: a secret, but at 0.55, far
             # under exposure's 0.9.
             [
               "schema_field",
               inspect(S.Heuristic),
               ":label",
               "secret",
               "credential",
               "550",
               "550"
             ],
             [
               "schema_field",
               inspect(S.Heuristic),
               ":totp_seed",
               "secret",
               "credential",
               "830",
               "830"
             ]
           ]
  end

  test "permille clamps and rounds" do
    assert Sensitivity.permille(0.9349) == 935
    assert Sensitivity.permille(1.2) == 1000
    assert Sensitivity.permille(-0.1) == 0
    assert Sensitivity.permille(1) == 1000
  end
end
