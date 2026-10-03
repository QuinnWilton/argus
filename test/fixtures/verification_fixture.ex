defmodule Argus.Test.Fixtures.Verification do
  @moduledoc false
  @compile {:no_warn_undefined, [JOSE.JWT, JOSE.JWS]}

  def strict_unchecked(key, algorithms, token) do
    {_, claims, _} = JOSE.JWT.verify_strict(key, algorithms, token)
    {:ok, claims}
  end

  def jws_unchecked(key, token) do
    {_, payload, _} = JOSE.JWS.verify(key, token)
    {:ok, payload}
  end

  def strict_checked(key, algorithms, token) do
    case JOSE.JWS.verify_strict(key, algorithms, token) do
      {true, payload, _} -> {:ok, payload}
      _ -> :error
    end
  end

  def claim_unchecked(key, token) do
    {_, %{fields: %{"subject" => subject}}, _} = JOSE.JWT.verify(key, token)
    {:ok, subject}
  end

  def claim_checked(key, token) do
    {true, %{fields: %{"subject" => subject}}, _} = JOSE.JWT.verify(key, token)
    {:ok, subject}
  end

  def accepts_failed_verdict(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    if valid == false, do: {:ok, payload}, else: :error
  end

  def verdict_forwarded(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    {valid, payload}
  end

  def verdict_passed(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    consume(valid, payload)
  end

  def different_verdict(key, token, other) do
    {_, payload, _} = JOSE.JWT.verify(key, token)
    {valid, _, _} = JOSE.JWT.verify(key, other)
    {valid, payload}
  end

  def forwarded_then_used(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    consume(valid, payload)
    {:ok, payload}
  end

  def twice_unchecked(key, token) do
    {_, payload, _} = JOSE.JWT.verify(key, token)
    consume(payload)
    {:ok, payload}
  end

  def public_key_ignored(data, signature, key) do
    :public_key.verify(data, :sha256, signature, key)
    {:ok, data}
  end

  def public_key_checked(data, signature, key) do
    if :public_key.verify(data, :sha256, signature, key, []), do: {:ok, data}, else: :error
  end

  def crypto_ignored(data, signature, key) do
    :crypto.verify(:rsa, :sha256, data, signature, key, [])
    {:ok, data}
  end

  def crypto_returned(data, signature, key) do
    :crypto.verify(:rsa, :sha256, data, signature, key)
  end

  defp consume(payload), do: {:ok, payload}
  defp consume(valid, payload), do: {valid, payload}
end
