defmodule Argus.Mix.Diagnostics do
  @moduledoc """
  Report entries and notices as `Mix.Task.Compiler.Diagnostic`s: what
  the `:argus` compiler returns to Mix, and to an editor through it.

  A finding's diagnostic follows the roux/haruspex pattern: a short
  `message` (`[argus.<analysis>] <title>`) and an integer line
  `position` for editors, with the full frame
  (`Argus.Report.Pentiment`) in `details`, without color. The terminal
  gets the same frame in color (`rendered`'s `ansi`, which `print/1`
  puts on stderr): pentiment leaves the color out when ANSI is off.

  A notice (`Argus.Report.Notice`) — no solver, an analysis that
  degraded, a module extraction could not read — is about the run, not
  the code: its diagnostic is the project's (`mix.exs`, position 0),
  with the notice's own wording.
  """

  alias Argus.Report
  alias Argus.Report.{Entry, Notice}

  @compiler "argus"

  @typedoc "A diagnostic paired with its colored rendering for the terminal."
  @type rendered :: %{diagnostic: Mix.Task.Compiler.Diagnostic.t(), ansi: String.t()}

  @doc """
  Each entry's diagnostic, in the entries' order, its path shown
  relative to `cwd` (the `Diagnostic` keeps the absolute path).
  """
  @spec build([Entry.t()], String.t()) :: [rendered()]
  def build(entries, cwd), do: Enum.map(entries, &render_entry(&1, cwd))

  @doc "A notice's diagnostic: the project's, at position 0."
  @spec notice(Notice.t()) :: rendered()
  def notice(%Notice{} = notice) do
    diagnostic = %Mix.Task.Compiler.Diagnostic{
      compiler_name: @compiler,
      file: Path.join(File.cwd!(), "mix.exs"),
      source: "mix.exs",
      position: 0,
      severity: mix_severity(notice.severity),
      message: notice.message
    }

    %{diagnostic: diagnostic, ansi: Report.Text.notice(notice)}
  end

  @doc """
  Prints rendered diagnostics to stderr, frames separated by blank
  lines.
  """
  @spec print([rendered()]) :: :ok
  def print(rendered) do
    Enum.each(rendered, fn %{ansi: ansi} -> IO.puts(:stderr, ansi <> "\n") end)
  end

  defp render_entry(%Entry{} = entry, cwd) do
    {report, sources} = Report.Pentiment.report(entry, cwd)

    %{
      diagnostic: %Mix.Task.Compiler.Diagnostic{
        compiler_name: @compiler,
        file: entry.file,
        source: entry.file,
        position: entry.line,
        severity: mix_severity(entry.severity),
        message: "[#{Entry.code(entry)}] #{entry.title}",
        details: Pentiment.format(report, sources, colors: false)
      },
      ansi: Pentiment.format(report, sources, colors: true)
    }
  end

  defp mix_severity(:error), do: :error
  defp mix_severity(:warning), do: :warning
  defp mix_severity(:info), do: :information
end
