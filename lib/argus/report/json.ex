defmodule Argus.Report.Json do
  @moduledoc """
  The findings as JSON: a list with one object per entry, in the order
  of `Argus.Report.build/3`. The stable machine schema — the structured
  fields of a finding, never the rendered frame:

      [
        {
          "analysis": "coupling",
          "severity": "warning",
          "file": "lib/my_app/application.ex",
          "line": 12,
          "end_line": null,
          "title": "Coupled children under one_for_one",
          "at_label": "supervision tree defined here",
          "detail": "...",
          "help": ["..."],
          "provenance": "structural",
          "confidence": null,
          "related": [{"label": "coupling call", "file": "...", "line": 41, "end_line": null}]
        }
      ]

  Paths are relative to where the run was asked from. `analysis` is the
  analysis's name (the code a text report shows is `argus.<analysis>`).
  `provenance` is `"heuristic"` for a finding that rests on a prior
  (argus's layer-3 relations, `priors:` in the configuration), and
  `confidence` is then the prior's probability in thousandths; a
  structural finding's is `null`. `end_line` closes a multi-line span,
  else `null`.

  `title` names the class of the finding and never the instance: the
  values that tell two findings of one class apart (the message, the
  field, the table) are in `at_label`, the label of the finding's own
  line (`null` when the finding has none), and in `detail`.

  The keys come in the order above, whatever VM encodes them: an
  object's keys are written one by one, never from a map, whose atom
  keys iterate in the order the VM's atom table holds them.
  """

  alias Argus.Report
  alias Argus.Report.Entry

  @doc "The entries as one line of JSON, without a trailing newline."
  @spec encode([Entry.t()], String.t()) :: String.t()
  def encode(entries, cwd) do
    IO.iodata_to_binary(["[", Enum.map_intersperse(entries, ",", &entry(&1, cwd)), "]"])
  end

  @doc "Prints `encode/2` to stdout, with a newline."
  @spec print([Entry.t()], String.t()) :: :ok
  def print(entries, cwd), do: IO.puts(encode(entries, cwd))

  defp entry(%Entry{} = entry, cwd) do
    object(
      analysis: Atom.to_string(entry.analysis),
      severity: Atom.to_string(entry.severity),
      file: Report.relative(entry.file, cwd),
      line: entry.line,
      end_line: entry.end_line,
      title: entry.title,
      at_label: entry.at_label,
      detail: entry.detail,
      help: entry.help,
      provenance: Atom.to_string(entry.provenance),
      confidence: entry.confidence,
      related:
        {:raw,
         [
           "[",
           Enum.map_intersperse(entry.related, ",", fn related ->
             object(
               label: related.label,
               file: Report.relative(related.file, cwd),
               line: related.line,
               end_line: related.end_line
             )
           end),
           "]"
         ]}
    )
  end

  defp object(pairs) do
    [
      "{",
      Enum.map_intersperse(pairs, ",", fn {key, value} ->
        [JSON.encode!(Atom.to_string(key)), ":", value(value)]
      end),
      "}"
    ]
  end

  defp value({:raw, iodata}), do: iodata
  defp value(value), do: JSON.encode!(value)
end
