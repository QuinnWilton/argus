defmodule Argus.Priors.Questions.Sensitivity do
  @moduledoc """
  What an Ecto field holds, from its name and its siblings' names.

  `exposure` knows fifteen substrings (`api_key`, `password`, ...). A
  field the table cannot name — `totp_seed`, `teams_key`, `webhook_url`,
  a `secret_first` beside a `secret_second` — is one the model can, and a
  field the table over-matches (`api_key_count`) is one it can doubt.
  The calibration spike measured 98% precision at a probability of 0.9
  on names read from beams and on names of public projects' schemas,
  which is where `exposure`'s threshold comes from.

  Every field of a schema is asked in one request, the whole field list
  as the shared state; the answer per field is a `choice` over seven
  kinds and a `noul` for whether printing the value would leak. The row
  carries the coarse kind a rule reads (`secret | personal | none`), the
  kind chosen, and its probability in thousandths.
  """

  @behaviour Argus.Priors.Question

  @kinds %{
    "credential" => "secret",
    "password" => "secret",
    "token" => "secret",
    "pii" => "personal",
    "financial" => "personal",
    "health" => "personal",
    "none" => "none"
  }

  @criteria %{
    credential:
      "A secret granting access to another system: an API key, client secret, private or signing key, access key",
    password: "A user's password, or a password hash, for this system",
    token:
      "Bearer or session material with a lifetime: an access, refresh, session, auth, reset or confirmation token",
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
  def prompt_version, do: 1

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
    |> Enum.group_by(& &1.mod, & &1.field)
    |> Enum.sort()
    |> Enum.flat_map(fn {mod, fields} ->
      names = fields |> Enum.map(&strip/1) |> Enum.uniq() |> Enum.sort()
      redacted_names = redacted |> Map.get(mod, []) |> Enum.map(&strip/1) |> Enum.sort()

      for field <- Enum.sort(Enum.uniq(fields)) do
        %{
          id: {mod, field},
          batch_key: mod,
          state: %{
            schema_module: mod,
            field: strip(field),
            fields: names,
            redacted_fields: redacted_names
          }
        }
      end
    end)
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
    |> Enum.flat_map(fn {subject, i} ->
      field = subject.state.field

      [
        {"kind__#{i}",
         %{
           type: "choice",
           instructions:
             "What kind of data does the field `#{field}` hold? Judge from its name and the names around it.",
           criteria: @criteria
         }},
        {"must_redact__#{i}",
         %{
           type: "noul",
           instructions:
             "Printing the value of `#{field}` in a log line or an inspect output would leak a secret or personal data."
         }}
      ]
    end)
    |> Map.new()
  end

  @impl true
  def rows(subjects, answers) do
    subjects
    |> Enum.with_index()
    |> Enum.flat_map(fn {%{id: {mod, field}}, i} ->
      case answers["kind__#{i}"] do
        %{"choice" => detail, "probabilities" => probs} when is_map_key(@kinds, detail) ->
          p = probs |> Map.get(detail, 0.0) |> permille()
          [["schema_field", mod, field, @kinds[detail], detail, Integer.to_string(p)]]

        _ ->
          []
      end
    end)
  end

  @doc "A probability as an integer in thousandths, clamped to 0..1000."
  @spec permille(number()) :: 0..1000
  def permille(p) when is_number(p), do: p |> Kernel.*(1000) |> round() |> max(0) |> min(1000)

  defp strip(":" <> rest), do: rest
  defp strip(other), do: other
end
