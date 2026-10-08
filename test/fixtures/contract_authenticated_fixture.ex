# Deserialization of bytes an authenticated decryption or MAC check
# returned (clientlib/verification.dl's authenticated_payload_api): only
# a holder of the server's secret could have written them, so the term is
# one the server encoded. Shaped like attesto_phoenix's
# RefreshSuccessorCipher, which decodes `MessageEncryptor.decrypt/4`'s
# plaintext in a private helper.

defmodule Argus.Test.Fixtures.ContractSealed do
  @moduledoc false

  @compile {:no_warn_undefined, [Plug.Crypto, Plug.Crypto.MessageEncryptor, Phoenix.Token]}
  @compile {:no_warn_undefined, Plug.Crypto.MessageVerifier}

  alias Plug.Crypto.MessageEncryptor
  alias Plug.Crypto.MessageVerifier

  # The plaintext, handed to a private helper every caller hands the
  # same.
  def open(ciphertext, secret) when is_binary(ciphertext) do
    with {:ok, enc_key, sign_key} <- keys(secret),
         {:ok, encoded} <- MessageEncryptor.decrypt(ciphertext, "aad", enc_key, sign_key) do
      safe_decode(encoded)
    else
      _ -> :error
    end
  end

  defp keys(secret) when byte_size(secret) >= 32,
    do: {:ok, :crypto.hash(:sha256, ["enc:", secret]), :crypto.hash(:sha256, ["sign:", secret])}

  defp keys(_secret), do: :error

  def open_default(ciphertext, enc_key, sign_key) do
    case MessageEncryptor.decrypt(ciphertext, "v1", enc_key, sign_key) do
      {:ok, encoded} -> safe_decode(encoded)
      :error -> :error
    end
  end

  defp safe_decode(encoded) do
    {:ok, :erlang.binary_to_term(encoded, [:safe])}
  rescue
    ArgumentError -> :error
  end

  # A verified message decoded where it is checked.
  def verified(message, secret) do
    case MessageVerifier.verify(message, secret) do
      {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe])
      :error -> nil
    end
  end

  # A field of a token's verified term.
  def token_field(endpoint, token) do
    case Phoenix.Token.verify(endpoint, "salt", token, max_age: 60) do
      {:ok, %{"blob" => blob}} -> :erlang.binary_to_term(blob, [:safe])
      _ -> nil
    end
  end
end

defmodule Argus.Test.Fixtures.ContractUnsealed do
  @moduledoc false

  @compile {:no_warn_undefined, Plug.Crypto.MessageEncryptor}

  alias Plug.Crypto.MessageEncryptor

  # The same helper, but one caller hands it the caller's own bytes: still
  # reported.
  def open(ciphertext, enc_key, sign_key) do
    case MessageEncryptor.decrypt(ciphertext, "aad", enc_key, sign_key) do
      {:ok, encoded} -> decode(encoded)
      :error -> :error
    end
  end

  def peek(bytes), do: decode(bytes)

  defp decode(encoded), do: :erlang.binary_to_term(encoded, [:safe])

  # The same function hands the helper a payload and captures it for other
  # bytes: still reported.
  def open_each(ciphertext, enc_key, sign_key, others) do
    {:ok, encoded} = MessageEncryptor.decrypt(ciphertext, "aad", enc_key, sign_key)
    [captured_decode(encoded) | Enum.map(others, &captured_decode/1)]
  end

  defp captured_decode(encoded), do: :erlang.binary_to_term(encoded, [:safe])

  # Plain Base64 authenticates nothing: still reported.
  def unwrapped(text) do
    case Base.decode64(text) do
      {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe])
      :error -> nil
    end
  end

  # One path decrypts, the other does not: still reported.
  def either(ciphertext, enc_key, sign_key, sealed?) do
    bytes =
      if sealed? do
        {:ok, plain} = MessageEncryptor.decrypt(ciphertext, "aad", enc_key, sign_key)
        plain
      else
        ciphertext
      end

    :erlang.binary_to_term(bytes, [:safe])
  end
end
