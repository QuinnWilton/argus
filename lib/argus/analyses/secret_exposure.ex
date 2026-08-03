defmodule Argus.Analyses.SecretExposure do
  @moduledoc """
  Credentials an `inspect/1` will print.

  Ecto's `redact: true` keeps a field out of `inspect/1`, and it defaults to
  off — so a struct holding a third-party API key prints it in full into
  `Logger` calls, changeset error output, LiveView debug, crash reports and
  whatever error reporter is installed. Nothing at the field's definition
  site suggests that, and nothing fails when it happens.

  The field name is the only available signal for "is this a secret", which
  makes this a heuristic — and one of the few places a heuristic is clearly
  right, because nobody names a field `sendgrid_api_key` by accident.
  """

  @behaviour Argus.Analysis

  alias Argus.Findings

  @impl true
  def name, do: :secret_exposure

  @impl true
  def description, do: "schema fields holding secrets that inspect/1 will print"

  @impl true
  def rules_file, do: "analyses/secret_exposure.dl"

  @impl true
  def extractors, do: [Argus.Extractors.EctoSchema]

  @impl true
  def output_relations do
    [
      %{
        name: :unredacted_secret,
        fields: [
          {:mod, :symbol, "the schema"},
          {:field, :symbol, "the field"},
          {:kind, :symbol, "credential | password | token"},
          {:aware, :symbol, "whether the schema redacts anything else"}
        ],
        key: [:mod, :field],
        doc: "A secret-looking field that inspect/1 will print in full."
      }
    ]
  end

  @impl true
  def finding(:unredacted_secret, [mod, field, kind, aware]) do
    Findings.new(
      severity(kind),
      "#{mod}.#{field} is printed by inspect/1",
      "#{field} is not declared redact: true, so it appears in full wherever " <>
        "the struct is inspected — Logger calls, changeset errors, LiveView " <>
        "debug output, crash reports, and any error reporter that serialises " <>
        "state. " <>
        consequence(kind) <>
        " " <>
        awareness(aware, mod) <>
        " Add redact: true to the field.",
      at: Findings.at_module(mod)
    )
  end

  defp severity("credential"), do: :error
  defp severity(_other), do: :warning

  defp consequence("credential") do
    "This looks like a third-party credential, so leaking it hands over " <>
      "someone else's system rather than this one — the value is live until " <>
      "a human notices and rotates it."
  end

  defp consequence("password") do
    "A hash is not a plaintext password, but it is offline-attackable and " <>
      "does not belong in a log."
  end

  defp consequence("token"), do: "Bearer material, usable until it expires."
  defp consequence(_other), do: ""

  defp awareness("aware", mod) do
    "#{mod} redacts some other field, so the pattern is already known here " <>
      "and was not applied to this one — which makes this an oversight rather " <>
      "than an unfamiliar API."
  end

  defp awareness(_unaware, _mod), do: ""
end
