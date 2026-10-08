defmodule Argus.Test.Fixtures.RacesExposureSecretQualifiers do
  @moduledoc """
  A schema like attesto_phoenix's authorization: `access_token_jti` keeps
  the JWT ID of a minted token so a replayed code can deny it. A secret's
  name followed by a word for something about it (its id, kind, a hint
  or fingerprint of it) holds that fact, not the secret. The token, its
  raw value and a password's hash stay secrets.
  """
  @fields [
    :id,
    :access_token_jti,
    :api_key_id,
    :refresh_token_ids,
    :session_token_uuid,
    :access_token_type,
    :api_key_prefix,
    :password_hint,
    :api_key_last4,
    :private_key_fingerprint,
    :access_token_scopes,
    :client_secret_name,
    :private_key_path,
    :access_token,
    :api_key_raw,
    :password_hash
  ]

  def __schema__(:fields), do: @fields
  def __schema__(:redact_fields), do: []
  def __schema__(_other), do: nil

  def __schema__(:type, :id), do: :id
  def __schema__(:type, :api_key_id), do: :id
  def __schema__(:type, :refresh_token_ids), do: {:array, :id}
  def __schema__(:type, :session_token_uuid), do: :binary_id
  def __schema__(:type, :access_token_scopes), do: {:array, :string}
  def __schema__(:type, _field), do: :string
  def __schema__(:association, _field), do: nil
  def __schema__(:virtual_type, _field), do: nil
end
