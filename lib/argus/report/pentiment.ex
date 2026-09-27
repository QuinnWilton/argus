defmodule Argus.Report.Pentiment do
  @moduledoc """
  An entry as a pentiment frame: the one picture of a finding that the
  text report prints and a compiler diagnostic carries.

  - The primary anchor is an inline label under the code of its line,
    annotated with the finding's `at_label`. BEAM anchors are
    line-granular, so the span is the line's code extent (first
    non-blank column to the end of the trimmed line), read from the
    source file; a line that cannot be read degrades to column 1. A
    finding whose span closes on a later line brackets the lines from
    its anchor to the end.
  - Same-file related frames are secondary labels in the same excerpt;
    one in another file carries `source:` and renders as a
    `├─[file:line:col]` continuation frame against its own file. Labels
    on one span of one file are one label, their messages joined in
    order: a cycle's anchor and the frame for the edge it starts sit on
    the same call, and two underlines of one span read as two places.
  - `detail` renders as a note, each `help` as a help trailer.

  Sources are read from disk as the frame is rendered. A path that is
  not a source file (a beam, the anchor of a module that recorded no
  source) or cannot be read shows its header alone.
  """

  alias Argus.Report
  alias Argus.Report.Entry
  alias Pentiment.{Label, Source, Span}

  @doc """
  The frame of `entry`, its paths relative to `cwd`. `colors: true`
  colors it when ANSI is enabled (`IO.ANSI.enabled?/0`); `false` never.
  """
  @spec format(Entry.t(), String.t(), keyword()) :: String.t()
  def format(%Entry{} = entry, cwd, opts \\ []) do
    {report, sources} = report(entry, cwd)
    Pentiment.format(report, sources, colors: Keyword.get(opts, :colors, false))
  end

  @doc """
  The pentiment report of `entry` and the sources it reads, for a caller
  that formats it more than once (`Argus.Mix.Diagnostics`: plain for the
  diagnostic, in color for the terminal).
  """
  @spec report(Entry.t(), String.t()) :: {Pentiment.Report.t(), %{String.t() => Source.t()}}
  def report(%Entry{} = entry, cwd) do
    rel_file = Report.relative(entry.file, cwd)
    {build_report(entry, rel_file, cwd), build_sources(entry, rel_file, cwd)}
  end

  defp build_report(entry, rel_file, cwd) do
    [primary | related] = labels(entry, rel_file, cwd)

    entry.severity
    |> report_for(entry.title)
    |> Pentiment.Report.with_code(Entry.code(entry))
    |> Pentiment.Report.with_source(rel_file)
    |> Pentiment.Report.with_label(primary)
    |> Pentiment.Report.with_labels(related)
    |> Pentiment.Report.with_note(entry.detail)
    |> then(fn report -> Enum.reduce(entry.help, report, &Pentiment.Report.with_help(&2, &1)) end)
  end

  defp report_for(:error, message), do: Pentiment.Report.error(message)
  defp report_for(:warning, message), do: Pentiment.Report.warning(message)
  defp report_for(:info, message), do: Pentiment.Report.info(message)

  # The primary label first, then the related ones, one label per span.
  defp labels(entry, rel_file, cwd) do
    primary = {{rel_file, span(entry)}, entry.at_label, [style: style(entry)]}

    related =
      for related <- entry.related do
        rel_related = Report.relative(related.file, cwd)
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

  defp join(nil, message), do: message
  defp join(message, nil), do: message
  defp join(message, message), do: message
  defp join(first, second), do: first <> "; " <> second

  # A span that closes on a later line brackets the lines from its
  # anchor to the end; one that does not underlines its line.
  defp span(%{file: file, line: line} = anchored) do
    case anchored.end_line do
      end_line when is_integer(end_line) and end_line > line ->
        %Span.Position{start_column: col} = code_span(file, line)
        %Span.Position{end_column: end_col} = code_span(file, end_line)
        Span.position(line, col, end_line, end_col)

      _ ->
        code_span(file, line)
    end
  end

  defp style(%{line: line, end_line: end_line}) when is_integer(end_line) and end_line > line,
    do: :bracket

  defp style(_anchored), do: :inline

  # The code extent of a line: BEAM anchors carry no column, so the
  # label spans from the first non-blank character to the end of the
  # trimmed line. An unreadable source degrades to a one-column span.
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
    related_files = for related <- entry.related, do: Report.relative(related.file, cwd)

    for rel <- Enum.uniq([rel_file | related_files]), into: %{} do
      {rel, load_source(rel, cwd)}
    end
  end

  defp load_source(rel, cwd) do
    path = Path.expand(rel, cwd)

    if Path.extname(rel) in [".ex", ".exs", ".erl", ".hrl"] and File.regular?(path) do
      case File.read(path) do
        {:ok, content} -> Source.from_string(rel, content)
        {:error, _} -> Source.named(rel)
      end
    else
      Source.named(rel)
    end
  end
end
