defmodule Argus.Test.Support.HashedSecret do
  @moduledoc false
  def __schema__(:fields), do: [:api_key_hash, :api_key]
  def __schema__(:redact_fields), do: []
  def __schema__(_other), do: nil
end
