defmodule Argus.Locate.Source.Elixir do
  @moduledoc """
  The last step of an anchor, taken in the source.

  A bytecode anchor stops at what the compiler kept. Every function an
  Ecto schema generates carries the `schema do` line, so a finding about
  one field can name the field (`Argus.Findings` `at_source`) and leave
  the looking to whoever has the file: the first line at or after the
  bytecode anchor that contains the fragment as a whole token, or the
  bytecode anchor itself when no line does or the file cannot be read.

  A whole token is the fragment with no identifier character on either
  side — `:api_key` in `field :api_key, :string` and `[:api_key]`, not in
  `:api_key_count`, `:api_key?` or `::api_key` (a colon before it means
  it is not that atom).
  """

  @identifier ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_?!@:"

  @doc """
  The line of `fragment` at or after `line` in the file at `path`.
  """
  @spec refine(String.t(), pos_integer(), String.t() | nil) :: pos_integer()
  def refine(_path, line, nil), do: line

  def refine(path, line, fragment) when is_binary(fragment) and fragment != "" do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.drop(line - 1)
        |> Enum.find_index(&contains_token?(&1, fragment))
        |> case do
          nil -> line
          offset -> line + offset
        end

      {:error, _} ->
        line
    end
  end

  @doc """
  The last line of the source block the anchor at `line` sits in, for a
  span the bytecode could not close: a finding names the block
  (`Argus.Findings` `to_block`) and the source is read for its end.

  - `:guard` — the `rescue`/`catch`/`after` clauses guarding the anchored
    line: the first such keyword after it, no deeper than the anchor, to
    the `end` at the keyword's own indentation.
  - `:receive` — the `receive do` the anchor opens, to its `end`.
  - `:clause` — the function clause the anchor heads, to its `end`.
  - `:function` — every consecutive clause of the anchored function
    (attributes and comments between clauses allowed), to the last
    clause's `end`.

  Nil when the shape is not there — no keyword before the block closes,
  a one-line clause, a file that cannot be read — so the frame falls
  back to the anchor line. Formatting is the evidence here, not
  bytecode; the scan is bounded and every mismatch fails closed.
  """
  @spec block_end(String.t(), pos_integer(), :guard | :receive | :clause | :function | nil) ::
          pos_integer() | nil
  def block_end(_path, _line, nil), do: nil

  def block_end(path, line, kind) do
    case File.read(path) do
      {:ok, content} ->
        lines = content |> String.split("\n") |> List.to_tuple()

        case block_last_line(lines, line, kind) do
          last when is_integer(last) and last > line -> last
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  @scan_limit 400
  @guards ~w(catch rescue after else)

  @doc """
  The keyword of the guard the anchor at `line` sits in — `"rescue"`,
  `"catch"` or `"after"` — or nil. Bytecode cannot tell a rescue from a
  catch, so a finding's prose says `{guard}` where the word goes and
  this is what fills it in.
  """
  @spec guard_keyword(String.t(), pos_integer()) :: String.t() | nil
  def guard_keyword(path, line) do
    with {:ok, content} <- File.read(path),
         lines = content |> String.split("\n") |> List.to_tuple(),
         {:ok, anchor} <- fetch(lines, line),
         {:ok, keyword_line} <- guard_keyword(lines, line + 1, indent(anchor), @scan_limit),
         {:ok, keyword} <- fetch(lines, keyword_line) do
      first_word(keyword)
    else
      _ -> nil
    end
  end

  defp block_last_line(lines, line, :guard) do
    with {:ok, anchor} <- fetch(lines, line),
         anchor_indent = indent(anchor),
         {:ok, keyword_line} <- guard_keyword(lines, line + 1, anchor_indent, @scan_limit),
         {:ok, keyword} <- fetch(lines, keyword_line),
         {:ok, end_line} <- closing_end(lines, keyword_line + 1, indent(keyword), @scan_limit) do
      last_code_line(lines, end_line - 1, keyword_line)
    else
      _ -> nil
    end
  end

  defp block_last_line(lines, line, :receive) do
    with {:ok, anchor} <- fetch(lines, line),
         true <- Regex.match?(~r/\breceive\s*(do\b|$)/, anchor),
         {:ok, end_line} <- closing_end(lines, line + 1, indent(anchor), @scan_limit) do
      last_code_line(lines, end_line - 1, line)
    else
      _ -> nil
    end
  end

  defp block_last_line(lines, line, :clause) do
    case clause_end(lines, line) do
      {:ok, last, _after} -> last
      _ -> nil
    end
  end

  defp block_last_line(lines, line, :function) do
    with {:ok, head} <- fetch(lines, line),
         [_, name] <- Regex.run(~r/^\s*defp?\s+([a-zA-Z_][\w?!]*)/, head) do
      function_end(lines, line, name, indent(head), nil)
    else
      _ -> nil
    end
  end

  # The clause headed at `line`: its last code line (the head itself for
  # a `do:` one-liner) and the line after the clause.
  defp clause_end(lines, line) do
    with {:ok, head} <- fetch(lines, line),
         true <- Regex.match?(~r/^\s*defp?\s/, head) do
      if Regex.match?(~r/,\s*do:/, head) do
        {:ok, line, line + 1}
      else
        case closing_end(lines, line + 1, indent(head), @scan_limit) do
          {:ok, end_line} -> {:ok, last_code_line(lines, end_line - 1, line), end_line + 1}
          :error -> :error
        end
      end
    else
      _ -> :error
    end
  end

  # Consecutive clauses of one function, attributes and comments between.
  defp function_end(lines, line, name, indent, last) do
    with {:ok, head} <- fetch(lines, line),
         true <- indent(head) == indent,
         true <- Regex.match?(~r/^\s*defp?\s+#{Regex.escape(name)}\b/, head),
         {:ok, clause_last, after_clause} <- clause_end(lines, line) do
      next = next_code_line(lines, after_clause, @scan_limit)
      function_end(lines, next, name, indent, clause_last)
    else
      _ -> last
    end
  end

  defp guard_keyword(_lines, _from, _indent, 0), do: :error

  defp guard_keyword(lines, from, anchor_indent, budget) do
    case fetch(lines, from) do
      {:ok, text} ->
        cond do
          blank?(text) ->
            guard_keyword(lines, from + 1, anchor_indent, budget - 1)

          indent(text) < anchor_indent and first_word(text) in @guards ->
            {:ok, from}

          # The block closed, or another definition began, before any
          # guard: the anchored call is not guarded here.
          indent(text) < anchor_indent and
              (first_word(text) == "end" or Regex.match?(~r/^\s*def(p|module)?\s/, text)) ->
            :error

          true ->
            guard_keyword(lines, from + 1, anchor_indent, budget - 1)
        end

      :error ->
        :error
    end
  end

  # The `end` at exactly `indent`, skipping deeper ones.
  defp closing_end(_lines, _from, _indent, 0), do: :error

  defp closing_end(lines, from, indent, budget) do
    case fetch(lines, from) do
      {:ok, text} ->
        cond do
          String.trim(text) == "end" and indent(text) == indent -> {:ok, from}
          not blank?(text) and indent(text) < indent -> :error
          true -> closing_end(lines, from + 1, indent, budget - 1)
        end

      :error ->
        :error
    end
  end

  defp last_code_line(lines, from, floor) when from > floor do
    case fetch(lines, from) do
      {:ok, text} -> if blank?(text), do: last_code_line(lines, from - 1, floor), else: from
      :error -> floor
    end
  end

  defp last_code_line(_lines, _from, floor), do: floor

  defp next_code_line(_lines, from, 0), do: from

  defp next_code_line(lines, from, budget) do
    case fetch(lines, from) do
      {:ok, text} ->
        if blank?(text) or Regex.match?(~r/^\s*(@|#)/, text),
          do: next_code_line(lines, from + 1, budget - 1),
          else: from

      :error ->
        from
    end
  end

  defp fetch(lines, line) when line >= 1 and line <= tuple_size(lines),
    do: {:ok, elem(lines, line - 1)}

  defp fetch(_lines, _line), do: :error

  defp indent(text), do: String.length(text) - String.length(String.trim_leading(text))
  defp blank?(text), do: String.trim(text) == ""
  defp first_word(text), do: text |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd()

  @doc """
  Whether `text` contains `fragment` with no identifier character on
  either side.
  """
  @spec contains_token?(String.t(), String.t()) :: boolean()
  def contains_token?(text, fragment) do
    size = byte_size(fragment)

    text
    |> :binary.matches(fragment)
    |> Enum.any?(fn {pos, ^size} ->
      boundary?(text, pos - 1) and boundary?(text, pos + size)
    end)
  end

  defp boundary?(_text, at) when at < 0, do: true

  defp boundary?(text, at) do
    at >= byte_size(text) or :binary.at(text, at) not in @identifier
  end
end
