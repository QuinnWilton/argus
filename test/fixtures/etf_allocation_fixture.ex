defmodule Argus.Test.Fixtures.EtfAllocation do
  @moduledoc false
  @compile {:no_warn_undefined, Plug.Crypto}

  def direct(bytes), do: :erlang.binary_to_term(bytes)
  def safe_option(bytes), do: :erlang.binary_to_term(bytes, [:safe])
  def non_executable(bytes), do: Plug.Crypto.non_executable_binary_to_term(bytes, [:safe])
  def encoded_cap(bytes) when byte_size(bytes) <= 10_240, do: non_executable(bytes)
  def fixed_literal, do: :erlang.binary_to_term(<<131, 97, 1>>, [:safe])

  def prefix(<<131, 80, _::binary>>), do: :error
  def prefix(bytes), do: :erlang.binary_to_term(bytes, [:safe])

  def helper(values) do
    with {:ok, decoded} <- Base.decode64(values),
         :ok <- check(decoded, 10_240) do
      non_executable(decoded)
    end
  end

  def wrong_value(bytes, other) do
    with :ok <- check(other, 10_240), do: non_executable(bytes)
  end

  def late(bytes) do
    decoded = non_executable(bytes)
    :ok = check(bytes, 10_240)
    decoded
  end

  def partial(bytes, guarded?) do
    if guarded?, do: :ok = check(bytes, 10_240)
    non_executable(bytes)
  end

  def rescued(bytes) do
    try do
      :ok = check(bytes, 10_240)
    rescue
      _ -> :ok
    end

    non_executable(bytes)
  end

  def rescued_prefix(bytes) do
    try do
      case bytes do
        <<131, 80, _::binary>> -> raise ArgumentError
        _ -> :ok
      end
    rescue
      ArgumentError -> :ok
    end

    non_executable(bytes)
  end

  def changed_bytes(bytes) do
    with :ok <- check(bytes, 10_240) do
      <<_, _, rest::binary>> = bytes
      non_executable(rest)
    end
  end

  def wrong_prefix(<<131, 79, _::binary>>), do: :error
  def wrong_prefix(bytes), do: non_executable(bytes)

  def exact_short(<<131, 80>>), do: :error
  def exact_short(bytes), do: non_executable(bytes)

  def checked_and_literal(bytes) do
    with :ok <- check(bytes, 10_240) do
      first = non_executable(bytes)
      second = non_executable(<<131, 97, 1>>)
      {first, second}
    end
  end

  defp check(<<131, 80, _::binary>>, _max), do: :error
  defp check(bytes, max) when byte_size(bytes) > max, do: :error
  defp check(_bytes, _max), do: :ok
end

defmodule Argus.Test.Fixtures.EtfAllocation.CapturedDelegate do
  @moduledoc false

  def decode_many(values), do: Enum.map(values, &decode/1)
  def guarded(<<131, 80, _::binary>>), do: :error
  def guarded(bytes), do: decode(bytes)
  defp decode(bytes), do: :erlang.binary_to_term(bytes, [:safe])
end

defmodule Argus.Test.Fixtures.EtfAllocation.PrivateDelegate do
  @moduledoc false

  def guarded(<<131, 80, _::binary>>), do: :error
  def guarded(bytes), do: decode(bytes)
  defp decode(bytes), do: :erlang.binary_to_term(bytes, [:safe])
end

defmodule Argus.Test.Fixtures.EtfAllocation.ExportedDelegate do
  @moduledoc false
  @compile {:no_warn_undefined, Plug.Crypto}

  def decode(bytes), do: Plug.Crypto.non_executable_binary_to_term(bytes, [:safe])

  def guarded(<<131, 80, _::binary>>), do: :error
  def guarded(bytes), do: decode(bytes)
end
