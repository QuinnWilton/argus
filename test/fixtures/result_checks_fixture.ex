defmodule Argus.Test.Fixtures.ResultChecks do
  @moduledoc false
  @compile {:no_warn_undefined, [JOSE.JWT]}

  def unchecked(key, token) do
    {_, payload, _} = JOSE.JWT.verify(key, token)
    {:ok, payload}
  end

  def tagged(key, token) do
    case JOSE.JWT.verify(key, token) do
      {true, payload, _} -> {:ok, payload}
      _ -> :error
    end
  end

  def separate_boolean(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    if valid == true, do: consume(payload), else: :error
  end

  def truthy(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    if valid, do: consume(payload), else: :error
  end

  def wrong_result(key, token, other) do
    {_, payload, _} = JOSE.JWT.verify(key, token)
    {true, _, _} = JOSE.JWT.verify(key, other)
    consume(payload)
  end

  def after_use(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    consume(payload)
    true = valid
    :ok
  end

  def one_branch(key, token, check?) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    if check?, do: true = valid
    consume(payload)
  end

  def rejecting(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)
    if valid != true, do: raise(ArgumentError)
    consume(payload)
  end

  def catches_rejection(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)

    try do
      if valid != true, do: raise(ArgumentError)
    rescue
      ArgumentError -> :continue
    end

    consume(payload)
  end

  def selecting(key, token) do
    {valid, payload, _} = JOSE.JWT.verify(key, token)

    case valid do
      true -> consume(payload)
      false -> :error
      :unknown -> :unknown
    end
  end

  def generic_tag(key, token) do
    case external_result(key, token) do
      {:ok, payload} -> consume(payload)
      _ -> :error
    end
  end

  def forwards(key, token), do: JOSE.JWT.verify(key, token)
  def wraps(key, token), do: {:result, JOSE.JWT.verify(key, token)}

  def discarded(key, token) do
    JOSE.JWT.verify(key, token)
    :ok
  end

  def raises_payload(key, token) do
    {_, payload, _} = JOSE.JWT.verify(key, token)
    :erlang.error(payload)
  end

  def scalar_ignored(algorithm, digest, data, signature, key) do
    :crypto.verify(algorithm, digest, data, signature, key)
    :ok
  end

  def scalar_checked(algorithm, digest, data, signature, key) do
    true = :crypto.verify(algorithm, digest, data, signature, key)
    :ok
  end

  defp consume(payload), do: {:ok, payload}
  defp external_result(key, token), do: JOSE.JWT.verify(key, token)
end
