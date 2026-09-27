defmodule Argus.Report do
  @moduledoc """
  What a run found, made ready to show: every frontend — the `:argus`
  Mix compiler, `mix argus`, the `argus` escript and the rebar3 plugin,
  which relays the escript — renders the same entries in the same order.

  `build/3` takes each analysis's placed findings (`Argus.Located`, as
  `Argus.Driver.Result` carries them) and

    1. refines each place from its source (`Argus.Report.Entry`),
       leaving out a finding outside the program;
    2. leaves out the findings in a file the configuration ignores
       (`ignore: [files: globs]`, matched against the path relative to
       where the run was asked from): an ignored file's facts still feed
       every cross-module analysis, so reports are suppressed, truth is
       not;
    3. applies the configuration's severity overrides;
    4. sorts, most severe first, then by file, line, analysis and title;
       findings no key tells apart stay in their analysis's order.

  The entries then go to one of three renderers: `Argus.Report.Text`
  (pentiment frames, the notices and a summary, on stderr),
  `Argus.Report.Json` (the machine schema) or `Argus.Mix.Diagnostics`
  (a compiler diagnostic per entry). What a reader should know about the
  run itself — no solver, an analysis that degraded, a module extraction
  could not read — is an `Argus.Report.Notice`, in one wording for every
  frontend.
  """

  alias Argus.Report.Entry

  @doc """
  The entries to show for `located` (each analysis's placed findings, or
  why it degraded: a degraded analysis has no entries, and a notice
  says so) under `config`, with paths matched relative to `cwd`.
  """
  @spec build(
          %{optional(atom()) => {:ok, [Argus.Located.t()]} | {:error, term()}},
          Argus.Config.t(),
          String.t()
        ) :: [Entry.t()]
  def build(located, %Argus.Config{} = config, cwd) when is_map(located) do
    for {_analysis, {:ok, placed}} <- Enum.sort(located),
        one <- placed,
        %Entry{} = entry <- [Entry.from_located(one)],
        not ignored_file?(entry.file, config, cwd) do
      %{entry | severity: Map.get(config.severity, entry.analysis, entry.severity)}
    end
    |> Enum.sort_by(&{severity_rank(&1.severity), &1.file, &1.line, &1.analysis, &1.title})
  end

  @doc """
  The `N findings (x errors, y warnings, z infos)` summary line.

      iex> Argus.Report.summary([])
      "0 findings"
  """
  @spec summary([Entry.t()]) :: String.t()
  def summary([]), do: "0 findings"

  def summary(entries) do
    counts = Enum.frequencies_by(entries, & &1.severity)

    breakdown =
      [
        part(counts[:error], "error"),
        part(counts[:warning], "warning"),
        part(counts[:info], "info")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    total = length(entries)
    "#{total} finding#{plural(total)} (#{breakdown})"
  end

  defp part(nil, _label), do: nil
  defp part(count, label), do: "#{count} #{label}#{plural(count)}"

  defp plural(1), do: ""
  defp plural(_), do: "s"

  @doc """
  `path` relative to `cwd` when it lies under it, else as it is. macOS
  spells a temporary directory both `/var/...` and `/private/var/...`
  (the one a symlink to the other), and a recorded path may carry
  either: both spellings are tried.
  """
  @spec relative(String.t(), String.t()) :: String.t()
  def relative(path, cwd) do
    case Path.relative_to(path, cwd) do
      ^path ->
        stripped = strip_private(path)

        case Path.relative_to(stripped, strip_private(cwd)) do
          ^stripped -> path
          rel -> rel
        end

      rel ->
        rel
    end
  end

  defp strip_private("/private/" <> rest), do: "/" <> rest
  defp strip_private(path), do: path

  @doc "Where a severity ranks: `:error` first."
  @spec severity_rank(Argus.Findings.severity()) :: 0..2
  def severity_rank(:error), do: 0
  def severity_rank(:warning), do: 1
  def severity_rank(:info), do: 2

  defp ignored_file?(file, config, cwd) do
    rel = relative(file, cwd)
    Enum.any?(config.ignore_files, &matches_glob?(rel, &1))
  end

  # Glob matching without touching the filesystem: the pattern the way
  # Path.wildcard understands it, as a regex.
  defp matches_glob?(path, glob) do
    regex =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> then(&Regex.compile!("^" <> &1 <> "$"))

    Regex.match?(regex, path)
  end
end
