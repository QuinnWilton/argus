defmodule Argus.Test.Fixtures.SecurityValues do
  @moduledoc false
  @compile {:no_warn_undefined, [Plug.HTML, Phoenix.HTML]}

  def same_field(%{name: first}, %{name: second}) do
    consume(first, second)
  end

  def tuple_fields(result) do
    {verified, claims, _signature} = result
    consume(verified, claims)
  end

  def separate_results(first, second) do
    one = source(first)
    two = source(second)
    consume(one, two)
  end

  def bounded(bytes) when byte_size(bytes) <= 4096, do: consume(bytes)

  def rejects_large(bytes) do
    if byte_size(bytes) >= 4096, do: raise(ArgumentError)
    consume(bytes)
  end

  def wrong_value(bytes, other) when byte_size(other) <= 4096, do: consume(bytes)

  def checked_after(bytes) do
    result = consume(bytes)
    if byte_size(bytes) > 4096, do: raise(ArgumentError)
    result
  end

  def partial_guard(bytes, check?) do
    if check? and byte_size(bytes) > 4096, do: raise(ArgumentError)
    consume(bytes)
  end

  def rescued_guard(bytes) do
    try do
      if byte_size(bytes) > 4096, do: raise(ArgumentError)
    rescue
      ArgumentError -> :ok
    end

    consume(bytes)
  end

  def basename(bytes), do: consume(Path.basename(bytes))

  def unrelated_basename(bytes, other) do
    consume(Path.basename(other))
    consume(bytes)
  end

  def basename_one_branch(bytes, safe?) do
    value = if safe?, do: Path.basename(bytes), else: bytes
    consume(value)
  end

  def basename_both_branches(bytes, other, flag) do
    value = if flag, do: Path.basename(bytes), else: Path.basename(other)
    consume(value)
  end

  def expanded(bytes), do: consume(Path.expand(bytes))
  def html(bytes), do: consume(Plug.HTML.html_escape(bytes))
  def html_binary(bytes), do: consume(IO.iodata_to_binary(Plug.HTML.html_escape(bytes)))
  def html_concat(bytes), do: consume("<b>" <> Plug.HTML.html_escape(bytes) <> "</b>")
  def phoenix_html(bytes), do: consume(Phoenix.HTML.html_escape(IO.iodata_to_binary(bytes)))
  def phoenix_safe_tuple(bytes), do: consume(Phoenix.HTML.html_escape({:safe, bytes}))
  def phoenix_unknown(bytes), do: consume(Phoenix.HTML.html_escape(bytes))
  def raw_html(bytes), do: consume(Phoenix.HTML.raw(bytes))
  def replaced(bytes), do: consume(String.replace(bytes, "'", "''"))
  defp consume(value), do: value
  defp consume(first, second), do: {first, second}
  defp source(value), do: {:ok, value}
end
