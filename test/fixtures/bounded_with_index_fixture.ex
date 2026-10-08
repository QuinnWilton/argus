defmodule Argus.Test.Fixtures.BoundedWithIndex do
  @moduledoc false
  # The index Enum.with_index/2 pairs each element with is a counter, not
  # data from the enumerable: sql's decoder names its strides decode_1,
  # decode_2, ... after their positions. Each safe shape has a twin that
  # makes the atom of the element, or of a caller's offset. A finding is
  # per sink, so each shape has its own helper.

  def build_decoder(types) do
    strides = Enum.chunk_every(types, 8)
    count = length(strides)
    for {stride, index} <- Enum.with_index(strides, 1), do: stride(stride, index, count)
  end

  defp stride(types, index, count) do
    name = :"decode_#{index}"
    next = if index == count, do: nil, else: :"decode_#{index + 1}"
    {name, next, types}
  end

  def build_streamed(types) do
    types |> Stream.with_index() |> Enum.map(fn {type, index} -> streamed(type, index) end)
  end

  defp streamed(type, index), do: {type, :"stream_#{index}"}

  def build_enumerated(types) do
    for {index, type} <- :lists.enumerate(types), do: enumerated(type, index)
  end

  defp enumerated(type, index), do: {type, :"enum_#{index}"}

  def build_named(types) do
    for {type, index} <- Enum.with_index(types, 1), do: named(type, index)
  end

  defp named(type, index), do: {index, :"named_#{type}"}

  def build_enumerated_named(types) do
    for {index, type} <- :lists.enumerate(types), do: enumerated_named(type, index)
  end

  defp enumerated_named(type, index), do: {index, :"enum_named_#{type}"}

  def build_from(types, offset) do
    for {type, index} <- Enum.with_index(types, offset), do: offset_stride(type, index)
  end

  defp offset_stride(type, index), do: {type, :"offset_#{index}"}
end
