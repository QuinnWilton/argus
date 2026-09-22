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
  demand anyway. A count under a current name passes through.
  """

  alias Argus.Analysis

  @typedoc "A note about an entry that could not be carried over mechanically."
  @type note :: {:ambiguous, old :: String.t(), count :: non_neg_integer(), [atom()]}

  @doc """
  Migrates one analyzer's `%{"name" => count}` map.

  Returns the migrated map and the notes for entries dropped as ambiguous.
  Unknown names (neither current nor retired) are kept as they are.
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
  Rewrites the `expectations:` block of an encore manifest in place.

  The block is re-rendered from the migrated maps (comments inside it do
  not survive; those around it do). Returns the notes per analyzer.
  """
  @spec migrate_manifest(Path.t()) :: {:ok, [{atom(), [note()]}]} | {:error, term()}
  def migrate_manifest(path) do
    with {:ok, source} <- File.read(path),
         {manifest, _} <- Code.eval_string(source, [], file: path),
         %{expectations: expectations} when is_map(expectations) <- manifest,
         {:ok, {start, stop}} <- expectations_span(source) do
      migrated =
        for {analyzer, counts} <- expectations, into: %{} do
          {analyzer, migrate_counts(counts)}
        end

      block = render_expectations(Map.new(migrated, fn {a, {m, _}} -> {a, m} end))

      File.write!(
        path,
        String.slice(source, 0, start) <> block <> String.slice(source, stop..-1//1)
      )

      {:ok, for({a, {_, notes}} <- migrated, notes != [], do: {a, notes})}
    else
      %{} -> {:error, :no_expectations}
      {:error, _} = error -> error
      other -> {:error, {:unexpected, other}}
    end
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

  defp render_expectations(expectations) do
    analyzers =
      for {analyzer, counts} <- Enum.sort(expectations) do
        entries =
          counts
          |> Enum.sort()
          |> Enum.map_join(",\n", fn {name, count} -> ~s(      "#{name}" => #{count}) end)

        if entries == "",
          do: "    #{analyzer}: %{}",
          else: "    #{analyzer}: %{\n#{entries}\n    }"
      end

    "  expectations: %{\n" <> Enum.join(analyzers, ",\n") <> "\n  },"
  end
end
