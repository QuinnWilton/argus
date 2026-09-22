defmodule Argus.Migrate do
  @moduledoc """
  Carries finding counts pinned under retired analysis names over to the
  concerns those names' findings live in now.

  A count pinned under a retired name is a count of that name's findings.
  When every finding the name produced lives in one concern today, the
  count simply moves (and adds to whatever else lands there). When the
  name's findings are spread over several concerns (`supervision` spans
  coupling, structure, startup and shutdown), nothing here can say how
  the count splits, so the entry is dropped from the map and reported: it
  needs measuring and pinning by hand, which is what encore's manifests
  demand anyway. A zero is the exception: it says each of those concerns
  has none of that name's findings, so it lands as a zero under every
  target (never overriding a count already there). A count under a
  current name passes through.
  """

  alias Argus.Analysis

  @typedoc "A note about an entry that could not be carried over mechanically."
  @type note :: {:ambiguous, old :: String.t(), count :: non_neg_integer(), [atom()]}

  @doc """
  Migrates one analyzer's `%{"name" => count}` map.

  Returns the migrated map and the notes for entries dropped as ambiguous.
  Unknown names (neither current nor retired) are kept as they are.

  Order does not matter: a zero from a name spanning several concerns
  never replaces a count, and a count adds to such a zero.
  """
  @spec migrate_counts(%{String.t() => non_neg_integer()}) ::
          {%{String.t() => non_neg_integer()}, [note()]}
  def migrate_counts(counts) when is_map(counts) do
    current = MapSet.new(Analysis.builtin_analyses(), &Atom.to_string/1)

    Enum.reduce(counts, {%{}, []}, fn {name, count}, {acc, notes} ->
      if MapSet.member?(current, name) do
        {Map.update(acc, name, count, &(&1 + count)), notes}
      else
        case targets(name) do
          [] ->
            {Map.put(acc, name, count), notes}

          [target] ->
            {Map.update(acc, Atom.to_string(target), count, &(&1 + count)), notes}

          many when count == 0 ->
            {Enum.reduce(many, acc, &Map.put_new(&2, Atom.to_string(&1), 0)), notes}

          many ->
            {acc, [{:ambiguous, name, count, many} | notes]}
        end
      end
    end)
    |> then(fn {acc, notes} -> {acc, Enum.reverse(notes)} end)
  end

  # The distinct concerns a retired name's findings live in now.
  defp targets(name) do
    case Analysis.alias(String.to_atom(name)) do
      {:ok, entries} -> entries |> Enum.map(& &1.analysis) |> Enum.uniq()
      :error -> []
    end
  end

  @doc """
  Rewrites the pinned counts of an encore manifest in place.

  Only the named analyzers' maps inside the `expectations:` block are
  re-rendered (by default every analyzer whose map names something the
  alias table knows); everything else in the file, comments between the
  maps included, is kept byte for byte. Returns the notes per analyzer.

  Options:

    * `:analyzers` — the analyzer keys to migrate (atoms).
  """
  @spec migrate_manifest(Path.t(), keyword()) :: {:ok, [{atom(), [note()]}]} | {:error, term()}
  def migrate_manifest(path, opts \\ []) do
    with {:ok, source} <- File.read(path),
         {manifest, _} <- Code.eval_string(source, [], file: path),
         %{expectations: expectations} when is_map(expectations) <- manifest,
         {:ok, {start, stop}} <- expectations_span(source) do
      analyzers = Keyword.get_lazy(opts, :analyzers, fn -> retired_analyzers(expectations) end)
      block = String.slice(source, start, stop - start)

      result =
        Enum.reduce_while(analyzers, {:ok, block, []}, fn analyzer, {:ok, block, notes} ->
          with {:ok, counts} <- Map.fetch(expectations, analyzer),
               {:ok, {from, to}} <- analyzer_span(block, analyzer) do
            {migrated, analyzer_notes} = migrate_counts(counts)
            rendered = render_counts(analyzer, migrated)

            block = String.slice(block, 0, from) <> rendered <> String.slice(block, to..-1//1)

            notes =
              if analyzer_notes == [], do: notes, else: notes ++ [{analyzer, analyzer_notes}]

            {:cont, {:ok, block, notes}}
          else
            :error -> {:halt, {:error, {:unknown_analyzer, analyzer}}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      with {:ok, block, notes} <- result do
        File.write!(
          path,
          String.slice(source, 0, start) <> block <> String.slice(source, stop..-1//1)
        )

        {:ok, notes}
      end
    else
      %{} -> {:error, :no_expectations}
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
  end

  # The analyzers whose pinned names include one the alias table retires.
  defp retired_analyzers(expectations) do
    for {analyzer, counts} <- Enum.sort(expectations),
        Enum.any?(counts, fn {name, _} -> targets(name) != [] end),
        do: analyzer
  end

  # The formatted manifest keeps `expectations: %{` at two spaces of
  # indentation and closes the block with `  },` or `  }` on its own line.
  defp expectations_span(source) do
    case :binary.match(source, "\n  expectations: %{") do
      {at, _} ->
        start = at + 1

        case :binary.match(source, "\n  }", scope: {start, byte_size(source) - start}) do
          {close, _} ->
            stop = close + byte_size("\n  }")
            stop = if String.at(source, stop) == ",", do: stop + 1, else: stop
            {:ok, {start, stop}}

          :nomatch ->
            {:error, :unterminated_expectations}
        end

      :nomatch ->
        {:error, :no_expectations}
    end
  end

  # One analyzer's map inside the block: `    argus: %{` through the
  # matching `    }` on its own line, or through the `}` that closes a
  # map written on one line.
  defp analyzer_span(block, analyzer) do
    open = "\n    #{analyzer}: %{"

    case :binary.match(block, open) do
      {at, len} ->
        from = at + 1
        after_open = at + len
        rest = binary_part(block, after_open, byte_size(block) - after_open)
        line = rest |> String.split("\n", parts: 2) |> hd()

        one_line = String.trim_trailing(line, ",")

        if String.ends_with?(one_line, "}") do
          {:ok, {from, after_open + byte_size(one_line)}}
        else
          case :binary.match(rest, "\n    }") do
            {close, _} -> {:ok, {from, after_open + close + byte_size("\n    }")}}
            :nomatch -> {:error, {:unterminated_analyzer, analyzer}}
          end
        end

      :nomatch ->
        {:error, {:analyzer_not_found, analyzer}}
    end
  end

  defp render_counts(analyzer, counts) do
    entries =
      counts
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {name, count} -> ~s(      "#{name}" => #{count}) end)

    if entries == "",
      do: "    #{analyzer}: %{}",
      else: "    #{analyzer}: %{\n#{entries}\n    }"
  end
end
