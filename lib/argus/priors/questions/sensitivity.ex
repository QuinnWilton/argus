defmodule Argus.Priors.Questions.Sensitivity do
  @moduledoc """
  What an Ecto field holds, from its name, its type and the schema
  around it.

  `exposure` knows fifteen substrings (`api_key`, `password`, ...). A
  field the table cannot name — `totp_seed`, `teams_key`, `nkey_seed`,
  a `secret_first` beside a `secret_second` — is one the model can, and a
  field the table over-matches (`api_key_count`) is one it can doubt.

  Every field of a schema is asked in one request. The shared state is
  the schema: its module, every field with its Ecto type (a
  `Sequin.Encrypted.Field`, an `embeds_one Sequin.Sinks.Gcp.Credentials`
  says what a bare name does not) and the fields already redacted. The
  answer per field is a `choice` over nine kinds, and two of them exist
  to say what a secret-sounding name holds when it is not the secret: a
  `secret_reference` (a key's id or name, a handle to credentials kept
  elsewhere) and a `public_key` (the public half of a pair). Version 1
  had neither, so the probability that a field was *about* a secret had
  nowhere to go but `credential`: on 32 corpus checkouts four of its six
  warnings were a public key, two public key ids and a
  `credentials_ref`. Version 2 answers those `none` or below 0.9 while
  the real ones (`nkey_seed`, `jwt`, an embedded GCP credential) stay
  at 0.95 and above.

  The row carries the coarse kind a rule reads (`secret | personal |
  none`), the likeliest fine kind within it and that kind's probability,
  and last the coarse kind's own probability: the sum over its fine
  kinds. A rule gates on the sum. `jwt` at 0.89 token and 0.11
  credential is a secret at 1.00 — the model is sure it is one and
  unsure only which — where the chosen kind's 0.89 alone falls under
  `exposure`'s 0.9. A reference and a public key are details of `none`,
  so their mass counts against a secret, never for it.

  The coarse kind is the one with the most mass, which is the chosen
  kind's class unless the rest outweigh it (`none` at 0.4 against token
  and credential at 0.3 each is a secret at 0.6); a tie goes to the
  chosen kind's class.
  """

  @behaviour Argus.Priors.Question

  @kinds %{
    "credential" => "secret",
    "password" => "secret",
    "token" => "secret",
    "secret_reference" => "none",
    "public_key" => "none",
    "pii" => "personal",
    "financial" => "personal",
    "health" => "personal",
    "none" => "none"
  }

  @criteria %{
    credential:
      "The secret value itself, granting access to another system: an API key, client secret, private or signing key, key seed, access key",
    password: "A user's password, or a password hash, for this system",
    token:
      "The bearer or session token value itself: an access, refresh, session, auth, reset or confirmation token",
    secret_reference:
      "Names or points to a secret without holding its value: a key id or key name, a key prefix, a reference, path or handle to credentials stored elsewhere",
    public_key:
      "The public half of a key pair, a certificate, or a key published by design: safe to share",
    pii:
      "Personal data identifying a person: email, name, address, phone, national id, birth date, IP address",
    financial:
      "Payment or banking data: card or account numbers, balances or charges tied to a person",
    health: "Medical or health information",
    none:
      "Not sensitive: identifiers, timestamps, status flags, counts, content, settings that are not secrets"
  }

  @impl true
  def relation, do: :prior_sensitive

  @impl true
  def prompt_version, do: 2

  @impl true
  def relations_read, do: [:schema_field, :redacted_field]

  @impl true
  def subjects(facts) do
    redacted =
      facts
      |> Map.get(:redacted_field, [])
      |> Enum.group_by(& &1.mod, & &1.field)

    facts
    |> Map.get(:schema_field, [])
    |> Enum.group_by(& &1.mod)
    |> Enum.sort()
    |> Enum.flat_map(fn {mod, rows} ->
      fields = shown_fields(rows)

      redacted_names =
        redacted |> Map.get(mod, []) |> Enum.map(&strip/1) |> Enum.uniq() |> Enum.sort()

      for field <- rows |> Enum.map(& &1.field) |> Enum.uniq() |> Enum.sort() do
        %{
          id: {mod, field},
          batch_key: mod,
          state: %{
            schema_module: mod,
            field: strip(field),
            fields: fields,
            redacted_fields: redacted_names
          }
        }
      end
    end)
  end

  # Each field by name with its type; a type the extractor could not read
  # is left out rather than shown as `dynamic`, which the model would
  # read as a claim about the field.
  defp shown_fields(rows) do
    rows
    |> Enum.uniq_by(& &1.field)
    |> Enum.map(fn row ->
      case Map.get(row, :type) do
        type when is_binary(type) and type not in ["", "dynamic"] ->
          %{name: strip(row.field), type: type}

        _ ->
          %{name: strip(row.field)}
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  @impl true
  def state([first | _] = _subjects) do
    %{
      subject_kind: "schema_field",
      schema_module: first.state.schema_module,
      fields: first.state.fields,
      redacted_fields: first.state.redacted_fields
    }
  end

  @impl true
  def questions(subjects) do
    subjects
    |> Enum.with_index()
    |> Map.new(fn {subject, i} ->
      field = subject.state.field

      {"kind__#{i}",
       %{
         type: "choice",
         instructions:
           "What does the field `#{field}` hold? Judge from its name, its type and the schema around it. " <>
             "A secret's id, name or public half is not the secret.",
         criteria: @criteria
       }}
    end)
  end

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: {mod, field}}, i} ->
      case answers["kind__#{i}"] do
        %{"choice" => choice, "probabilities" => probs} when is_map_key(@kinds, choice) ->
          {kind, mass} = coarse(choice, probs)
          {detail, p} = likeliest(kind, choice, probs)

          [
            [
              "schema_field",
              mod,
              field,
              kind,
              detail,
              Integer.to_string(permille(p)),
              Integer.to_string(permille(mass))
            ]
          ]

        _ ->
          []
      end
    end)
  end

  # The coarse kind with the most mass, the chosen kind's class on a tie.
  defp coarse(choice, probs) do
    chosen = @kinds[choice]

    @kinds
    |> Map.values()
    |> Enum.uniq()
    |> Enum.map(&{&1, mass(&1, probs)})
    |> Enum.sort_by(fn {kind, m} -> {-m, kind != chosen, kind} end)
    |> hd()
  end

  defp mass(kind, probs) do
    for {detail, ^kind} <- @kinds, reduce: 0.0 do
      acc -> acc + probability(probs, detail)
    end
  end

  # The likeliest fine kind of a coarse one, the model's choice on a tie.
  defp likeliest(kind, choice, probs) do
    for({detail, ^kind} <- @kinds, do: {detail, probability(probs, detail)})
    |> Enum.sort_by(fn {detail, p} -> {-p, detail != choice, detail} end)
    |> hd()
  end

  defp probability(probs, detail) do
    case Map.get(probs, detail) do
      p when is_number(p) -> p
      _ -> 0.0
    end
  end

  @doc "A probability as an integer in thousandths, clamped to 0..1000."
  @spec permille(number()) :: 0..1000
  def permille(p) when is_number(p), do: p |> Kernel.*(1000) |> round() |> max(0) |> min(1000)

  defp strip(":" <> rest), do: rest
  defp strip(other), do: other
end
