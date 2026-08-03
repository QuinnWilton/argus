defmodule Argus.Test.Fixtures.Secret do
  @moduledoc """
  Fixtures for the secret-exposure analysis.

  Ecto is not a dependency here, so `__schema__/1` is written by hand. That
  is the contract anyway — the analysis reads the compiled function, not the
  macro that usually writes it — and a hand-written clause compiles to the
  same `select_val` dispatch a real schema does.
  """

  defmodule Exposed do
    @moduledoc "Credentials with no redaction anywhere."
    def __schema__(:fields), do: [:id, :name, :sendgrid_api_key, :smtp_password]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end

  defmodule PartlyRedacted do
    @moduledoc """
    Redacts one field and not the other. The interesting case: the pattern
    is known here and was not applied, which is an oversight rather than an
    unfamiliar API.
    """
    def __schema__(:fields), do: [:id, :api_key, :client_secret]
    def __schema__(:redact_fields), do: [:api_key]
    def __schema__(_other), do: nil
  end

  defmodule Redacted do
    @moduledoc "Everything sensitive is redacted."
    def __schema__(:fields), do: [:id, :access_token, :password]
    def __schema__(:redact_fields), do: [:access_token, :password]
    def __schema__(_other), do: nil
  end

  defmodule Ordinary do
    @moduledoc "No field name suggests a secret."
    def __schema__(:fields), do: [:id, :title, :body, :inserted_at]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil
  end
end
