defmodule Argus.Facts do
  @moduledoc """
  Schema-driven typed decoding of raw fact rows for in-process consumers.

  `Argus.Pipeline.Emit` produces facts as lists of string fields — the right
  shape for Souffle `.facts` files, but stringly for Elixir consumers. This
  module decodes those rows against `Argus.Schema`: each row becomes a map
  keyed by the schema's field names, with values decoded by field kind
  (numbers and labels to integers, instruction IDs to `Argus.InstrId`
  structs).

  Decoding is *strict*: a row that doesn't match its relation's schema (wrong
  arity, non-numeric number, malformed instruction ID) raises — such a row can
  only come from a bug in an emitter or extractor, and surfacing it loudly at
  the decode boundary beats consumers silently dropping it. Relations not in
  the schema (custom extractor output) pass through undecoded.

  Eventually emission itself may become typed, with stringification pushed to
  the `.facts` writer; this decoder is the compatible first step.
  """

  alias Argus.{InstrId, Schema}

  @type row :: %{atom() => term()}
  @type t :: %{atom() => [row()]}

  @doc """
  Decode a raw facts map (`relation => [[String.t()]]`) into typed rows.
  """
  @spec decode(%{atom() => [[String.t()]]}) :: t()
  def decode(raw) when is_map(raw) do
    Map.new(raw, fn {relation, rows} -> {relation, decode_relation(relation, rows)} end)
  end

  defp decode_relation(relation, rows) do
    case Schema.fetch(relation) do
      {:ok, %{fields: fields}} -> Enum.map(rows, &decode_row(relation, fields, &1))
      :error -> rows
    end
  end

  defp decode_row(relation, fields, row) when length(fields) == length(row) do
    fields
    |> Enum.zip(row)
    |> Map.new(fn {{name, kind, _doc}, value} -> {name, decode_value(relation, kind, value)} end)
  end

  defp decode_row(relation, fields, row) do
    raise ArgumentError,
          "relation #{relation} expects #{length(fields)} fields, got row #{inspect(row)}"
  end

  defp decode_value(_relation, :symbol, value), do: value
  defp decode_value(_relation, :func_id, value), do: value

  defp decode_value(relation, kind, value) when kind in [:number, :label] do
    case Integer.parse(value) do
      {int, ""} ->
        int

      _ ->
        raise ArgumentError,
              "relation #{relation}: expected #{kind}, got #{inspect(value)}"
    end
  end

  defp decode_value(relation, :instr_id, value) do
    case InstrId.parse(value) do
      {:ok, id} ->
        id

      :error ->
        raise ArgumentError,
              "relation #{relation}: malformed instruction ID #{inspect(value)}"
    end
  end
end
