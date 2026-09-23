defmodule Scry.Diagnostics do
  @moduledoc """
  Resolved findings → pentiment frames → `Mix.Task.Compiler.Diagnostic`.

  Driver-side presentation: nothing here is memoized, and the query
  graph never renders. Each resolved finding (file + line + prose +
  labelled related anchors, from `Scry.Analysis.analysis_diagnostics`)
  becomes one pentiment report:

  - the primary anchor is an inline label under the code of its line,
    annotated with the finding's `at_label`. BEAM anchors are
    line-granular, so the span is the line's code extent (first
    non-blank column to the end of the trimmed line), read from the
    source file; a line that cannot be read degrades to column 1;
  - same-file related anchors are secondary inline labels in the same
    excerpt; cross-file related anchors carry `source:` and render as
    `├─[file:line:col]` continuation frames against their own file;
  - `detail` renders as a note, `help` entries as help trailers.

  The Mix bridge follows the roux/haruspex pattern: the `Diagnostic`
  carries a short `message` and an integer line `position` for editors,
  and the full rendered frame rides in `details` — `print/1` puts the
  frame on stderr. Terminal output re-renders with `colors: true`
  (pentiment itself degrades when stderr is not a TTY); `details` and
  the persisted sidecar stay color-free.

  File-level ignores apply here, at emission — an ignored file's facts
  still feed every cross-module analysis. Reports are suppressed, truth
  is not.
  """

  alias Pentiment.{Label, Report, Source, Span}

  @typedoc "A diagnostic paired with its ANSI rendering for terminal output."
  @type rendered :: %{diagnostic: Mix.Task.Compiler.Diagnostic.t(), ansi: String.t()}

  @doc """
  The filtered, severity-overridden, sorted finding entries — the shared
  substrate for both rendering (`build/3`) and machine formats
  (`Scry.Report.json/2`).

  `findings_by_file` merges every demanded analysis's resolved map.
  File-level ignores drop entries here; severity overrides apply here.
  """
  @spec resolve(%{optional(String.t()) => [map()]}, Scry.Config.t(), String.t()) :: [map()]
  def resolve(findings_by_file, %Scry.Config{} = config, cwd) do
    entries =
      for {file, entries} <- findings_by_file,
          not ignored_file?(file, config, cwd),
          entry <- entries do
        %{entry | severity: Map.get(config.severity, atomize_code(entry), entry.severity)}
      end

    Enum.sort_by(entries, &{severity_rank(&1.severity), &1.file, &1.line, &1.code, &1.title})
  end

  @doc """
  Builds diagnostics from `analysis_diagnostics` values, most severe
  first.

  Paths are relativized against `cwd` for display; the `Diagnostic`
  keeps the absolute path.
  """
  @spec build(%{optional(String.t()) => [map()]}, Scry.Config.t(), String.t()) :: [rendered()]
  def build(findings_by_file, %Scry.Config{} = config, cwd) do
    findings_by_file
    |> resolve(config, cwd)
    |> Enum.map(&render_entry(&1, cwd))
  end

  @doc """
  Relativizes an absolute path against `cwd`, tolerating the macOS
  `/var` ↔ `/private/var` symlink spelling difference.
  """
  @spec relative(String.t(), String.t()) :: String.t()
  def relative(path, cwd), do: relativize(path, cwd)

  @doc """
  Builds an infrastructure diagnostic (no source frame): souffle
  missing, an analysis degraded, and similar conditions that are about
  the run rather than the code.
  """
  @spec infrastructure(:error | :warning | :info, String.t()) :: rendered()
  def infrastructure(severity, message) do
    diagnostic = %Mix.Task.Compiler.Diagnostic{
      compiler_name: "scry",
      file: Path.join(File.cwd!(), "mix.exs"),
      source: "mix.exs",
      position: 0,
      severity: mix_severity(severity),
      message: message
    }

    %{diagnostic: diagnostic, ansi: "scry: #{message}"}
  end

  @doc """
  The notice for what extraction could not do on a module: the analyses
  ran on partial facts, so a finding that needed the rest may be missing.
  Distinct from an analysis that degraded, which reported nothing.
  """
  @spec extraction_error_message(%{name: String.t(), step: String.t(), reason: String.t()}) ::
          String.t()
  def extraction_error_message(%{name: name, step: "module", reason: reason}) do
    "#{name} could not be extracted (#{reason}); the analyses ran without its facts, " <>
      "so findings that involve it may be missing"
  end

  def extraction_error_message(%{name: name, step: "pipeline", reason: reason}) do
    "#{name} lost all its facts in extraction (#{reason}); the analyses ran without them, " <>
      "so findings that involve it may be missing — the next run extracts it again"
  end

  def extraction_error_message(%{name: name, step: step, reason: reason}) do
    "#{name}: the #{step} extraction step failed (#{reason}); the analyses ran on the rest " <>
      "of its facts, so findings that needed that step's may be missing"
  end

  @doc """
  The notice for a module more than one scanned ebin defines
  (`include_deps: true`): which beam is analyzed, and which are not.
  """
  @spec duplicate_message(module(), String.t(), [String.t()]) :: String.t()
  def duplicate_message(module, used, shadowed) do
    "#{inspect(module)} is defined in more than one ebin; analyzing " <>
      "#{relative(used, File.cwd!())} and not " <>
      Enum.map_join(shadowed, ", ", &relative(&1, File.cwd!()))
  end

  @doc """
  Prints rendered diagnostics to stderr, frames separated by blank
  lines.
  """
  @spec print([rendered()]) :: :ok
  def print(rendered) do
    Enum.each(rendered, fn %{ansi: ansi} -> IO.puts(:stderr, ansi <> "\n") end)
  end

  # ── report building ──────────────────────────────────────────────────

  defp render_entry(entry, cwd) do
    rel_file = relativize(entry.file, cwd)
    report = build_report(entry, rel_file, cwd)
    sources = build_sources(entry, rel_file, cwd)

    %{
      diagnostic: %Mix.Task.Compiler.Diagnostic{
        compiler_name: "scry",
        file: entry.file,
        source: entry.file,
        position: entry.line,
        severity: mix_severity(entry.severity),
        message: "[scry.#{entry.code}] #{entry.title}",
        details: Pentiment.format(report, sources, colors: false)
      },
      ansi: Pentiment.format(report, sources, colors: true)
    }
  end

  defp build_report(entry, rel_file, cwd) do
    [primary | related] = labels(entry, rel_file, cwd)

    entry.severity
    |> report_for("#{entry.title}")
    |> Report.with_code("scry.#{entry.code}")
    |> Report.with_source(rel_file)
    |> Report.with_label(primary)
    |> Report.with_labels(related)
    |> Report.with_note(entry.detail)
    |> then(fn report ->
      Enum.reduce(Map.get(entry, :help, []), report, &Report.with_help(&2, &1))
    end)
  end

  defp report_for(:error, message), do: Report.error(message)
  defp report_for(:warning, message), do: Report.warning(message)
  defp report_for(:info, message), do: Report.info(message)

  # The primary label first, then the related ones. Labels on the same
  # span of the same file are one label: a cycle's anchor and the frame
  # for the edge it starts sit on the same call, and two underlines of
  # one span, each with its own tail, read as two places. Their messages
  # join in order, and the first label keeps its place and priority.
  defp labels(entry, rel_file, cwd) do
    primary = {{rel_file, span(entry)}, Map.get(entry, :at_label), primary_opts(entry)}

    related =
      for related <- Map.get(entry, :related, []) do
        rel_related = relativize(related.file, cwd)
        opts = [priority: :secondary, style: style(related)]
        opts = if rel_related == rel_file, do: opts, else: Keyword.put(opts, :source, rel_related)
        {{rel_related, span(related)}, related.label, opts}
      end

    [primary | related]
    |> Enum.reduce([], fn {place, message, opts}, merged ->
      case List.keyfind(merged, place, 0) do
        {^place, first, first_opts} ->
          List.keyreplace(merged, place, 0, {place, join(first, message), first_opts})

        nil ->
          [{place, message, opts} | merged]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {{_file, span}, message, opts} ->
      Label.new(span, Keyword.put(opts, :message, message))
    end)
  end

  defp primary_opts(entry), do: [style: style(entry)]

  defp join(nil, message), do: message
  defp join(message, nil), do: message
  defp join(message, message), do: message
  defp join(first, second), do: first <> "; " <> second

  # A finding that closes a span brackets the lines from its anchor to
  # the end; one that does not underlines its line.
  defp span(%{file: file, line: line} = entry) do
    case Map.get(entry, :end_line) do
      end_line when is_integer(end_line) and end_line > line ->
        %Span.Position{start_column: col} = code_span(file, line)
        %Span.Position{end_column: end_col} = code_span(file, end_line)
        Span.position(line, col, end_line, end_col)

      _ ->
        code_span(file, line)
    end
  end

  defp style(entry) do
    case Map.get(entry, :end_line) do
      end_line when is_integer(end_line) and end_line > entry.line -> :bracket
      _ -> :inline
    end
  end

  # The code extent of a line: BEAM anchors carry no column, so the
  # label spans from the first non-blank character to the end of the
  # trimmed line. Unreadable sources degrade to a one-column span.
  defp code_span(file, line) do
    with {:ok, content} <- File.read(file),
         text when is_binary(text) <- Enum.at(String.split(content, "\n"), line - 1),
         trimmed = String.trim_trailing(text),
         leading = String.length(text) - String.length(String.trim_leading(text)),
         true <- String.length(trimmed) > leading do
      Span.position(line, leading + 1, line, String.length(trimmed) + 1)
    else
      _ -> Span.position(line, 1, line, 1)
    end
  end

  defp build_sources(entry, rel_file, cwd) do
    related_files =
      for related <- Map.get(entry, :related, []), do: relativize(related.file, cwd)

    for rel <- Enum.uniq([rel_file | related_files]), into: %{} do
      {rel, load_source(rel, cwd)}
    end
  end

  # Sources load from disk at render time. A path that is unreadable or
  # not Elixir source (the beam-path fallback anchor) degrades to a
  # name-only source: the frame header keeps file:line, the excerpt is
  # skipped.
  defp load_source(rel, cwd) do
    path = Path.expand(rel, cwd)

    if Path.extname(rel) in [".ex", ".exs", ".erl"] and File.regular?(path) do
      case File.read(path) do
        {:ok, content} -> Source.from_string(rel, content)
        {:error, _} -> Source.named(rel)
      end
    else
      Source.named(rel)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────

  defp ignored_file?(file, config, cwd) do
    rel = relativize(file, cwd)

    Enum.any?(config.ignore_files, fn glob ->
      matches_glob?(rel, glob)
    end)
  end

  # Glob matching without touching the filesystem: compile the pattern
  # the way Path.wildcard understands it, expressed as a regex.
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

  defp atomize_code(%{code: code}) when is_binary(code), do: String.to_existing_atom(code)

  defp relativize(path, cwd) do
    case Path.relative_to(path, cwd) do
      ^path ->
        # macOS: /var symlinks to /private/var, and anno paths can carry
        # either spelling. Retry with both sides normalized.
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

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2

  defp mix_severity(:error), do: :error
  defp mix_severity(:warning), do: :warning
  defp mix_severity(:info), do: :information
end
