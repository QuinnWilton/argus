defmodule Scry.Report do
  @moduledoc """
  Output formats for the standalone `mix scry` task.

  Text is the pentiment frames plus a summary line. JSON is the stable
  machine schema — the structured finding fields, never the rendered
  frames:

      [
        {
          "analysis": "coupling",
          "severity": "warning",
          "file": "lib/my_app/application.ex",
          "line": 12,
          "end_line": null,
          "title": "Coupled children under one_for_one",
          "detail": "...",
          "help": ["..."],
          "provenance": "structural",
          "confidence": null,
          "related": [{"label": "coupling call", "file": "...", "line": 41, "end_line": null}]
        }
      ]

  `provenance` is `"heuristic"` for a finding that rests on a prior
  (argus's layer-3 relations, `priors:` in the config), and `confidence`
  is then the prior's probability in thousandths; a structural finding's
  is `null`. `end_line` closes a multi-line span, else `null`.
  """

  @doc """
  Prints resolved entries as pentiment frames with a trailing summary.
  """
  @spec text([Scry.Diagnostics.rendered()]) :: :ok
  def text(rendered) do
    Scry.Diagnostics.print(rendered)
    IO.puts(:stderr, summary(Enum.map(rendered, & &1.diagnostic)))
    :ok
  end

  @doc """
  Encodes resolved finding entries as JSON on stdout.
  """
  @spec json([map()], String.t()) :: :ok
  def json(entries, cwd) do
    entries
    |> Enum.map(fn entry ->
      %{
        analysis: entry.code,
        severity: entry.severity,
        file: Scry.Diagnostics.relative(entry.file, cwd),
        line: entry.line,
        end_line: Map.get(entry, :end_line),
        title: entry.title,
        detail: entry.detail,
        help: Map.get(entry, :help, []),
        provenance: Map.get(entry, :provenance, :structural),
        confidence: Map.get(entry, :confidence),
        related:
          for related <- Map.get(entry, :related, []) do
            %{
              label: related.label,
              file: Scry.Diagnostics.relative(related.file, cwd),
              line: related.line,
              end_line: Map.get(related, :end_line)
            }
          end
      }
    end)
    |> JSON.encode!()
    |> IO.puts()
  end

  @doc """
  The `N findings (x errors, y warnings, z infos)` summary line.
  """
  @spec summary([Mix.Task.Compiler.Diagnostic.t()]) :: String.t()
  def summary([]), do: "0 findings"

  def summary(diagnostics) do
    counts = Enum.frequencies_by(diagnostics, & &1.severity)

    breakdown =
      [
        part(counts[:error], "error"),
        part(counts[:warning], "warning"),
        part(counts[:information], "info")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    total = length(diagnostics)
    "#{total} finding#{plural(total)} (#{breakdown})"
  end

  defp part(nil, _label), do: nil
  defp part(count, label), do: "#{count} #{label}#{plural(count)}"

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
