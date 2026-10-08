defmodule Argus.Corpus.Baseline do
  @moduledoc """
  What the corpus found before a change, to say what the change moved:
  every checkout's findings as one run left them, kept beside the
  checkout's manifest (`<checkout>/.argus/baseline-<worktree>`, one per
  argus worktree, as manifests are).

  A rule's own pairs say only that its finding appears and goes where it
  should; a change's reach is every other finding in the corpus. The
  first corpus run of a checkout records its findings, and every later
  run (`Argus.CorpusTest`, `mix argus.corpus diff`) compares against that
  record until `mix argus.corpus accept` takes the findings it sees as
  the new baseline. A run says what an edit added and removed, and
  keeps saying it for every edit after it, until the edits' sum is
  accepted.

  A finding is compared by what a reader of the report would call it:
  its analysis, title, severity, function and source line. Its prose is
  not compared: a reworded detail moves no finding.
  """

  alias Argus.Corpus

  @typedoc "A finding as a baseline holds it."
  @type entry :: {
          analysis :: atom(),
          title :: String.t(),
          severity :: atom(),
          function :: String.t() | nil,
          at :: String.t() | nil
        }

  @typedoc "What changed in one checkout: entries added and removed, each sorted."
  @type changes :: %{added: [entry()], removed: [entry()]}

  @doc "The fields of a finding its entry is made of (`entries/2`)."
  @spec fields() :: [atom()]
  def fields, do: [:analysis, :title, :severity, :module, :mfa, :file, :line]

  @doc """
  The entries of a checkout's findings, sorted; a finding's file is
  named relative to the checkout.
  """
  @spec entries(Corpus.checkout(), Argus.Findings.t() | %{findings: [map()]}) :: [entry()]
  def entries(%{dir: dir}, %{findings: findings}) do
    findings
    |> Enum.map(fn finding ->
      {finding.analysis, finding.title, finding.severity, function(finding), at(finding, dir)}
    end)
    |> Enum.sort()
  end

  defp function(%{mfa: {module, name, arity}}), do: "#{inspect(module)}.#{name}/#{arity}"
  defp function(%{module: module}) when module != nil, do: inspect(module)
  defp function(_finding), do: nil

  defp at(%{file: file} = finding, dir) when is_binary(file) do
    relative = if Path.type(file) == :absolute, do: Path.relative_to(file, dir), else: file

    case finding do
      %{line: line} when is_integer(line) -> "#{relative}:#{line}"
      _ -> relative
    end
  end

  defp at(_finding, _dir), do: nil

  @doc "Where this worktree keeps a checkout's baseline."
  @spec path(Corpus.checkout()) :: Path.t()
  def path(%{dir: dir}), do: Path.join([dir, ".argus", "baseline-" <> Corpus.worktree()])

  @doc "The checkout's baseline, or `:none` when no run recorded one."
  @spec read(Corpus.checkout()) :: {:ok, [entry()]} | :none
  def read(checkout) do
    with {:ok, binary} <- File.read(path(checkout)),
         {:ok, entries} when is_list(entries) <- decode(binary) do
      {:ok, entries}
    else
      _ -> :none
    end
  end

  # A baseline that does not decode (a write cut short, another
  # version's format) is no baseline: the next run records one afresh.
  defp decode(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  @doc """
  Records `entries` as the checkout's baseline, written beside it under
  a name of its own and renamed into place.
  """
  @spec write!(Corpus.checkout(), [entry()]) :: :ok
  def write!(checkout, entries) do
    target = path(checkout)
    File.mkdir_p!(Path.dirname(target))
    staging = "#{target}.#{:os.getpid()}.#{System.unique_integer([:positive])}"
    File.write!(staging, :erlang.term_to_binary(entries, [:deterministic]))
    File.rename!(staging, target)
  end

  @doc """
  What `current` has that `baseline` lacks, and the reverse, as
  multisets: a title reported twice in a function where it was once is
  one entry added.
  """
  @spec changes([entry()], [entry()]) :: changes()
  def changes(baseline, current) do
    %{added: Enum.sort(current -- baseline), removed: Enum.sort(baseline -- current)}
  end

  @doc """
  Compares a checkout's entries with its baseline, recording them as the
  baseline when it has none: `{:recorded, count}` then, or the changes.

  An analysis that `degraded` in the run (it timed out, say, under a
  loaded machine) reported nothing, which is no finding removed: its
  entries are left out of the comparison on both sides, and a run with
  one records no baseline (`{:unrecorded, degraded}`).
  """
  @spec compare(Corpus.checkout(), [entry()], [atom()]) ::
          {:recorded, non_neg_integer()} | {:unrecorded, [atom()]} | changes()
  def compare(checkout, entries, degraded \\ []) do
    kept = fn entries -> Enum.reject(entries, &(elem(&1, 0) in degraded)) end

    case {read(checkout), degraded} do
      {{:ok, baseline}, _} ->
        changes(kept.(baseline), kept.(entries))

      {:none, []} ->
        write!(checkout, entries)
        {:recorded, length(entries)}

      {:none, _} ->
        {:unrecorded, degraded}
    end
  end

  @doc "The analyses a run's results say degraded."
  @spec degraded(%{optional(:degraded) => [map()], optional(atom()) => term()}) :: [atom()]
  def degraded(results),
    do: results |> Map.get(:degraded, []) |> Enum.map(& &1.analysis) |> Enum.uniq()

  @doc """
  The changes across checkouts, by title: a line per analysis and title
  with what was added and removed, the checkouts' rows under each when
  `rows?`. Empty when nothing changed.
  """
  @spec report([{Corpus.checkout(), changes()}], keyword()) :: [String.t()]
  def report(changed, opts \\ []) do
    rows? = Keyword.get(opts, :rows, false)

    rows =
      for {co, %{added: added, removed: removed}} <- changed,
          {sign, entries} <- [{"+", added}, {"-", removed}],
          {analysis, title, severity, function, at} <- entries,
          do: {{analysis, title}, sign, co.name, severity, function, at}

    rows
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.sort_by(fn {{analysis, title}, rows} -> {-length(rows), analysis, title} end)
    |> Enum.flat_map(fn {{analysis, title}, rows} ->
      plus = Enum.count(rows, &(elem(&1, 1) == "+"))
      minus = length(rows) - plus
      counts = String.pad_trailing("+#{plus} -#{minus}", 10)
      heading = "#{counts} #{analysis}: #{title}"

      if rows?,
        do: [heading | Enum.map(Enum.sort_by(rows, &Tuple.delete_at(&1, 0)), &row/1)],
        else: [heading]
    end)
  end

  defp row({_title, sign, checkout, severity, function, at}) do
    where = Enum.reject([function, at], &is_nil/1) |> Enum.join(" ")
    "    #{sign} #{checkout}  #{where} (#{severity})"
  end
end
