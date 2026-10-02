defmodule Argus.Test.Fixtures.SecretPrecision do
  @moduledoc false

  defmodule BooleanToken do
    @moduledoc false
    def __schema__(:fields), do: [:id, :public_refresh_token, :token, :totp_seed, :access_token]
    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil

    def __schema__(:type, :id), do: :id
    def __schema__(:type, :public_refresh_token), do: :boolean
    def __schema__(:type, :token), do: :boolean
    def __schema__(:type, :totp_seed), do: :boolean
    def __schema__(:type, :access_token), do: :string
    def __schema__(:association, _field), do: nil
    def __schema__(:virtual_type, _field), do: nil
  end

  defmodule Values do
    @moduledoc false
    def __schema__(:fields),
      do: [
        :id,
        :public_refresh_token,
        :api_key_hash,
        :password,
        :unknown_secret,
        :custom_secret,
        :totp_seed
      ]

    def __schema__(:redact_fields), do: []
    def __schema__(_other), do: nil

    def __schema__(:type, :id), do: :id
    def __schema__(:type, :public_refresh_token), do: :string
    def __schema__(:type, :api_key_hash), do: :binary
    def __schema__(:type, :password), do: :string
    def __schema__(:type, :unknown_secret), do: {:unsupported, :shape}
    def __schema__(:type, :custom_secret), do: Argus.Test.Encrypted.Binary
    def __schema__(:type, :totp_seed), do: :string
    def __schema__(:association, _field), do: nil
    def __schema__(:virtual_type, _field), do: nil
  end
end
