defmodule Argus.Locate.Source.Erlang do
  @moduledoc """
  The last step of an anchor, taken in Erlang source
  (`Argus.Locate.Source`), on the file's tokens (`:erl_scan`) rather
  than its layout: Erlang's formatting says less than Elixir's, and its
  blocks are closed by tokens (`end`, `;`, `.`) wherever they fall.

  - `:guard` — the `catch` or `after` of the `try` whose body the anchor
    is in, to the last token before the `try`'s `end`. An anchor in the
    `of` clauses or the handlers themselves is not guarded by them: nil.
    An old-style `catch Expr` on the anchor's line is a guard whose
    keyword is `catch` and whose span is that line.
  - `:receive` — the `receive` on the anchor's line, to the last token
    before its `end` (its `after` clause included).
  - `:clause` — the function clause the anchor heads, to the `;` or `.`
    that ends it.
  - `:function` — every clause of the function the anchor heads, to the
    `.` that ends it.

  Nesting counts brackets (`(`, `[`, `{`, `<<`) and the keywords an
  `end` closes (`begin`, `case`, `if`, `receive`, `try`, `maybe`, and a
  `fun` that opens a body, not a `fun name/1` reference). A file that
  does not scan, or a shape not found where the anchor is, is nil: the
  frame keeps the bytecode's place.

  `refine/3` finds a fragment as `Argus.Locate.Source.Elixir` does: the
  first line at or after the anchor that holds it as a whole token.

  `line/2` undoes `-file` directives. A generated file — the Erlang a
  Gleam build writes (`-file("src/app/worker.gleam", 10).` before each
  function), a yecc or leex parser — renumbers what follows each
  directive, and the bytecode's lines are those numbers: the physical
  line is found from the one directive whose run of lines holds the
  number, and kept as it is when none does (the lines before the first
  directive) or more than one could.
  """

  @behaviour Argus.Locate.Source

  @openers [:"(", :"[", :"{", :"<<", :begin, :case, :if, :receive, :try, :maybe]
  @closers [:")", :"]", :"}", :">>", :end]

  @identifier ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@"

  @impl true
  @spec line(String.t(), pos_integer()) :: pos_integer()
  def line(path, line) do
    with [_ | _] = runs <- runs(path) do
      case for(
             {first, number, count} <- runs,
             line >= number,
             line < number + count,
             do: {first, number}
           ) do
        [{first, number}] -> first + (line - number)
        _ -> line
      end
    else
      _ -> line
    end
  end

  defp runs(path) do
    Argus.Locate.Source.read(path, :erlang_runs, fn ->
      case content(path) do
        {:ok, content} -> file_runs(String.split(content, "\n"))
        {:error, _} -> []
      end
    end)
  end

  defp content(path), do: Argus.Locate.Source.read(path, :content, fn -> File.read(path) end)

  # Each `-file(Name, Number).` directive's run: the physical line after
  # it, the number that line bears, and how many lines the run has (to
  # the next directive, or the end). The lines before the first directive
  # hold the module's attributes, not its code: a number no run holds is
  # kept as it is.
  defp file_runs(lines) do
    directives =
      for {text, index} <- Enum.with_index(lines, 1),
          [_, number] <- [Regex.run(~r/^\s*-file\("[^"]*",\s*(\d+)\)\s*\./, text)],
          do: {index, String.to_integer(number)}

    ends = Enum.map(Enum.drop(directives, 1), &elem(&1, 0)) ++ [length(lines) + 1]

    # The line after a directive bears its number plus one (epp numbers
    # the directive's own line with it).
    Enum.zip_with(directives, ends, fn {at, number}, next ->
      {at + 1, number + 1, next - at - 1}
    end)
  end

  @impl true
  @spec refine(String.t(), pos_integer(), String.t() | nil) :: pos_integer()
  def refine(_path, line, nil), do: line

  def refine(path, line, fragment) when is_binary(fragment) and fragment != "" do
    case content(path) do
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

  @impl true
  @spec block_end(String.t(), pos_integer(), Argus.Locate.Source.block() | nil) ::
          pos_integer() | nil
  def block_end(_path, _line, nil), do: nil

  def block_end(path, line, kind) do
    with {:ok, tokens} <- tokens(path),
         last when is_integer(last) and last > line <- last_line(tokens, line, kind) do
      last
    else
      _ -> nil
    end
  end

  @impl true
  @spec guard_keyword(String.t(), pos_integer()) :: String.t() | nil
  def guard_keyword(path, line) do
    with {:ok, tokens} <- tokens(path) do
      case guard(tokens, line) do
        {:ok, keyword, _end_at} -> Atom.to_string(keyword)
        :error -> if old_style_catch?(tokens, line), do: "catch"
      end
    else
      _ -> nil
    end
  end

  # A `catch Expr` on the line: a `catch` that is no section of a try
  # around it. It guards the expression it heads, so its keyword is
  # known; the span stays the line's (`block_end/3` is nil for it).
  defp old_style_catch?(tokens, line) do
    Enum.any?(on_line(tokens, line), fn i ->
      kind(elem(tokens, i)) == :catch and not try_section?(tokens, i)
    end)
  end

  defp try_section?(tokens, at) do
    case enclosing_try(tokens, at) do
      {:ok, try_at} -> try_section(tokens, try_at + 1, [:catch, :after]) == {:ok, at}
      :error -> false
    end
  end

  # ── Shapes ──────────────────────────────────────────────────────────

  defp last_line(tokens, line, :guard) do
    case guard(tokens, line) do
      {:ok, _keyword, end_at} -> line_before(tokens, end_at)
      :error -> nil
    end
  end

  defp last_line(tokens, line, :receive) do
    with {:ok, at} <- first_on_line(tokens, line, &(kind(&1) == :receive)),
         {:ok, end_at} <- matching_end(tokens, at) do
      line_before(tokens, end_at)
    else
      _ -> nil
    end
  end

  defp last_line(tokens, line, :clause) do
    with {:ok, head} <- function_head(tokens, line),
         {:ok, arrow} <- at_depth(tokens, head, &(kind(&1) == :->)),
         {:ok, stop} <- at_depth(tokens, arrow + 1, &(kind(&1) in [:";", :dot])) do
      line_of(elem(tokens, stop))
    else
      _ -> nil
    end
  end

  defp last_line(tokens, line, :function) do
    with {:ok, head} <- function_head(tokens, line),
         {:ok, dot} <- at_depth(tokens, head, &(kind(&1) == :dot)) do
      line_of(elem(tokens, dot))
    else
      _ -> nil
    end
  end

  defp last_line(_tokens, _line, _kind), do: nil

  # The `try` whose body holds the first token on `line` (past a `try`
  # the line opens with: `try f() catch ...` guards `f()`): its `catch` or
  # `after` keyword and the index of its `end`. Only an anchor in the
  # body is guarded: an `of`, `catch` or `after` of that try met before
  # the anchor means the anchor is past the body.
  defp guard(tokens, line) do
    with {:ok, anchor} <- first_on_line(tokens, line, &(kind(&1) != :try)),
         {:ok, try_at} <- enclosing_try(tokens, anchor),
         :ok <- in_body(tokens, try_at, anchor),
         {:ok, keyword_at} <- try_section(tokens, try_at + 1, [:catch, :after]),
         {:ok, end_at} <- matching_end(tokens, try_at) do
      {:ok, kind(elem(tokens, keyword_at)), end_at}
    end
  end

  # The innermost opener still open at `anchor`, when it is a `try`:
  # found walking back from the anchor, past every construct opened and
  # closed on the way (the file's tokens are balanced), so a question
  # about one anchor costs the distance to its enclosing construct, not
  # the length of the file.
  defp enclosing_try(tokens, anchor), do: enclosing(tokens, anchor - 1, 0)

  defp enclosing(_tokens, i, _depth) when i < 0, do: :error

  defp enclosing(tokens, i, depth) do
    cond do
      opener?(tokens, i) and depth == 0 ->
        if kind(elem(tokens, i)) == :try, do: {:ok, i}, else: :error

      opener?(tokens, i) ->
        enclosing(tokens, i - 1, depth - 1)

      kind(elem(tokens, i)) in @closers ->
        enclosing(tokens, i - 1, depth + 1)

      true ->
        enclosing(tokens, i - 1, depth)
    end
  end

  # No section keyword of the try between it and the anchor.
  defp in_body(tokens, try_at, anchor) do
    case try_section(tokens, try_at + 1, [:of, :catch, :after]) do
      {:ok, at} when at < anchor -> :error
      _ -> :ok
    end
  end

  # The first token of `keywords` at the depth of `from` (a try's body),
  # before the construct around it closes.
  defp try_section(tokens, from, keywords) do
    at_depth(tokens, from, &(kind(&1) in keywords))
  end

  # The first token from `from` on at depth 0 relative to it that `pred`
  # accepts; :error when the enclosing construct closes first.
  defp at_depth(tokens, from, pred), do: at_depth(tokens, from, pred, 0)

  defp at_depth(tokens, i, _pred, _depth) when i >= tuple_size(tokens), do: :error

  defp at_depth(tokens, i, pred, depth) do
    token = elem(tokens, i)

    cond do
      depth == 0 and pred.(token) -> {:ok, i}
      opener?(tokens, i) -> at_depth(tokens, i + 1, pred, depth + 1)
      kind(token) in @closers and depth == 0 -> :error
      kind(token) in @closers -> at_depth(tokens, i + 1, pred, depth - 1)
      true -> at_depth(tokens, i + 1, pred, depth)
    end
  end

  # The `end` that closes the opener at `at`.
  defp matching_end(tokens, at), do: at_depth(tokens, at + 1, &(kind(&1) == :end))

  # The function head `line` starts: an atom that begins a form or a
  # clause (after a `.` or a `;` at depth 0), followed by `(`.
  defp function_head(tokens, line) do
    with {:ok, at} <- first_on_line(tokens, line, fn _ -> true end),
         :atom <- kind(elem(tokens, at)),
         true <- at + 1 < tuple_size(tokens) and kind(elem(tokens, at + 1)) == :"(",
         true <- at == 0 or kind(elem(tokens, at - 1)) in [:dot, :";"] do
      {:ok, at}
    else
      _ -> :error
    end
  end

  # ── Tokens ──────────────────────────────────────────────────────────

  defp tokens(path) do
    Argus.Locate.Source.read(path, :erlang_tokens, fn ->
      with {:ok, content} <- content(path),
           {:ok, tokens, _end} <- :erl_scan.string(String.to_charlist(content), {1, 1}) do
        {:ok, List.to_tuple(tokens)}
      else
        _ -> :error
      end
    end)
  end

  defp kind(token), do: elem(token, 0)

  defp line_of(token) do
    case :erl_scan.location(token) do
      {line, _column} -> line
      line -> line
    end
  end

  # A `fun` opens a body when a clause follows (`fun(`, `fun Name(`),
  # not when it names a function (`fun f/1`, `fun m:f/1`).
  defp opener?(tokens, i) do
    case kind(elem(tokens, i)) do
      :fun -> fun_body?(tokens, i)
      kind -> kind in @openers
    end
  end

  defp fun_body?(tokens, i) do
    next = if i + 1 < tuple_size(tokens), do: kind(elem(tokens, i + 1))
    after_next = if i + 2 < tuple_size(tokens), do: kind(elem(tokens, i + 2))
    next == :"(" or (next == :var and after_next == :"(")
  end

  defp first_on_line(tokens, line, pred) do
    case Enum.find(on_line(tokens, line), &pred.(elem(tokens, &1))) do
      nil -> :error
      i -> {:ok, i}
    end
  end

  # The indexes of the tokens on `line`: the tokens are in the order of
  # their lines, so the first is found by bisection.
  defp on_line(tokens, line) do
    size = tuple_size(tokens)
    first = first_at_or_after(tokens, line, 0, size)

    Stream.iterate(first, &(&1 + 1))
    |> Enum.take_while(&(&1 < size and line_of(elem(tokens, &1)) == line))
  end

  defp first_at_or_after(_tokens, _line, low, high) when low >= high, do: low

  defp first_at_or_after(tokens, line, low, high) do
    mid = div(low + high, 2)

    if line_of(elem(tokens, mid)) < line,
      do: first_at_or_after(tokens, line, mid + 1, high),
      else: first_at_or_after(tokens, line, low, mid)
  end

  # The line of the last token before the one at `at`.
  defp line_before(_tokens, 0), do: nil
  defp line_before(tokens, at), do: line_of(elem(tokens, at - 1))

  # ── Fragments ───────────────────────────────────────────────────────

  defp contains_token?(text, fragment) do
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
