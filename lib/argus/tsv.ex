defmodule Argus.Tsv do
  @moduledoc """
  The tab-separated text of `.facts` files and of Souffle's outputs.

  Souffle reads a field as the raw bytes between two tabs, and a row as
  the bytes up to a newline, with no quoting and no escapes of its own. A
  value holding either character therefore moves every column after it:
  `def unquote(:"a\\tb")()` used to write a six-column `function_def` row
  into a five-column relation, and Souffle refused the whole program's
  facts over it. So every field is escaped on the way out and unescaped
  on the way back in:

  | character       | written as |
  | --------------- | ---------- |
  | `\\`            | `\\\\`     |
  | tab             | `\\t`      |
  | newline         | `\\n`      |
  | carriage return | `\\r`      |

  Souffle carries the escaped spelling through untouched, as an opaque
  symbol, so a derived row holds it as well and `decode/1` restores the
  value. The escape works character by character, so a rule that
  concatenates escaped symbols builds the escape of the concatenation;
  only a rule taking a substring in the middle of an escape, or measuring
  a symbol's length, sees the difference, and no shipped rule does
  either on a value that could hold one of these characters.

  A field that holds none of the four characters — nearly every field —
  is written and read as it is.
  """

  @special ["\\", "\t", "\n", "\r"]

  @doc """
  The lines of a `.facts` file holding `rows`, as iodata: each row's
  escaped fields joined by tabs and ended by a newline.
  """
  @spec encode([[String.t()]]) :: iodata()
  def encode(rows), do: Enum.map(rows, &encode_row/1)

  @doc "One row's line, newline included."
  @spec encode_row([String.t()]) :: iodata()
  def encode_row(row), do: [row |> Enum.map(&escape/1) |> Enum.intersperse("\t"), "\n"]

  @doc """
  The rows of a `.facts` or Souffle output file's `content`, each field
  unescaped.

  Only the newline that ends the last row is dropped: an empty line in
  the middle is a row whose single field is the empty string, not
  padding.
  """
  @spec decode(binary()) :: [[String.t()]]
  def decode(""), do: []

  def decode(content) when is_binary(content) do
    lines = String.split(content, "\n")
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

    # Nearly every file holds no backslash at all, and then there is
    # nothing to undo in any of its fields.
    if :binary.match(content, "\\") == :nomatch do
      Enum.map(lines, &String.split(&1, "\t"))
    else
      Enum.map(lines, fn line -> line |> String.split("\t") |> Enum.map(&unescape/1) end)
    end
  end

  @doc "A field as it is written, with its special characters escaped."
  @spec escape(String.t()) :: String.t()
  def escape(field) when is_binary(field) do
    case :binary.match(field, @special) do
      :nomatch -> field
      _ -> escape_all(field, [])
    end
  end

  defp escape_all(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp escape_all(<<"\\", rest::binary>>, acc), do: escape_all(rest, ["\\\\" | acc])
  defp escape_all(<<"\t", rest::binary>>, acc), do: escape_all(rest, ["\\t" | acc])
  defp escape_all(<<"\n", rest::binary>>, acc), do: escape_all(rest, ["\\n" | acc])
  defp escape_all(<<"\r", rest::binary>>, acc), do: escape_all(rest, ["\\r" | acc])
  defp escape_all(<<byte, rest::binary>>, acc), do: escape_all(rest, [byte | acc])

  @doc """
  The value a written field stands for. A backslash before any character
  other than the four this module escapes cannot have been written by
  `escape/1`, and is kept as it stands.
  """
  @spec unescape(String.t()) :: String.t()
  def unescape(field) when is_binary(field) do
    case :binary.match(field, "\\") do
      :nomatch -> field
      _ -> unescape_all(field, [])
    end
  end

  defp unescape_all(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp unescape_all(<<"\\\\", rest::binary>>, acc), do: unescape_all(rest, ["\\" | acc])
  defp unescape_all(<<"\\t", rest::binary>>, acc), do: unescape_all(rest, ["\t" | acc])
  defp unescape_all(<<"\\n", rest::binary>>, acc), do: unescape_all(rest, ["\n" | acc])
  defp unescape_all(<<"\\r", rest::binary>>, acc), do: unescape_all(rest, ["\r" | acc])
  defp unescape_all(<<byte, rest::binary>>, acc), do: unescape_all(rest, [byte | acc])
end
