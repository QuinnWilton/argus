defmodule Argus.Report do
  @moduledoc """
  Converts analysis results to JSON-serializable maps and writes them to disk.

  Used by the analysis harness to produce structured, machine-readable output
  for each analyzed project. Uses OTP's `:json` module for encoding, so no
  additional dependencies are needed.
  """

  @doc """
  Builds a structured report map for a single project.

  `meta` is a map with project metadata (name, path, build_system, module_count,
  timestamp, duration_ms).

  `analysis_results` is a list of `{analysis_name, {:ok, result} | {:error, reason}}`
  tuples, where `result` is the raw Souffle output map (`%{String.t() => [[String.t()]]}`)
  as returned by `Argus.Analysis.run/3`.

  Intermediate relations are filtered out — only output relations declared by
  each analysis module are included in the report.

  ## Options

  - `:findings` — an `Argus.Findings` struct; when given, the report gains
    an `"otp_findings"` section with severity-ranked, anchor-resolved
    findings (the reviewable view; the raw `"analyses"` rows stay unchanged
    for count-based consumers like the autoresearch loop).
  - `:lines` — an `Argus.Lines` table used to resolve each finding's anchor
    to a source line.
  """
  @spec build_project_report(map(), [{atom(), {:ok, map()} | {:error, term()}}], keyword()) ::
          map()
  def build_project_report(meta, analysis_results, opts \\ []) do
    analyses =
      Map.new(analysis_results, fn {name, outcome} ->
        {Atom.to_string(name), build_analysis_entry(name, outcome)}
      end)

    total_findings =
      analyses
      |> Map.values()
      |> Enum.map(& &1["finding_count"])
      |> Enum.sum()

    analyses_failed =
      analyses
      |> Map.values()
      |> Enum.count(&(&1["status"] == "error"))

    base = %{
      "meta" => meta,
      "analyses" => analyses,
      "summary" => %{
        "total_findings" => total_findings,
        "analyses_run" => map_size(analyses),
        "analyses_failed" => analyses_failed
      }
    }

    case Keyword.get(opts, :findings) do
      nil -> base
      findings -> Map.put(base, "otp_findings", findings_section(findings, opts[:lines]))
    end
  end

  # ── Findings serialization ──────────────────────────────────────────

  defp findings_section(findings, lines) do
    %{
      "findings" => Enum.map(findings.findings, &finding_to_json(&1, lines)),
      "by_severity" =>
        findings.findings
        |> Enum.frequencies_by(& &1.severity)
        |> Map.new(fn {severity, count} -> {Atom.to_string(severity), count} end),
      "degraded" =>
        Enum.map(findings.degraded, fn d ->
          %{"analysis" => Atom.to_string(d.analysis), "detail" => d.detail}
        end)
    }
  end

  @doc """
  Converts one finding to a JSON-serializable map.

  Anchors are rendered as strings (`module`, `mfa`, `instr`) and resolved
  to a source `line` when a line table is given; `nil` fields are omitted
  so the JSON stays clean of nulls.
  """
  @spec finding_to_json(Argus.Findings.finding(), Argus.Lines.t() | nil) :: map()
  def finding_to_json(finding, lines) do
    %{
      "analysis" => Atom.to_string(finding.analysis),
      "severity" => Atom.to_string(finding.severity),
      "title" => finding.title,
      "detail" => finding.detail,
      "module" => finding.module && inspect(finding.module),
      "mfa" => format_mfa(finding.mfa),
      "instr" => finding.instr && Argus.InstrId.format(finding.instr),
      "line" => resolve_line(finding, lines),
      "related" => Enum.map(finding.related, &related_to_json(&1, lines))
    }
    |> reject_nil_values()
  end

  defp related_to_json(related, lines) do
    %{
      "label" => related.label,
      "module" => related.module && inspect(related.module),
      "mfa" => format_mfa(related.mfa),
      "instr" => related.instr && Argus.InstrId.format(related.instr),
      "line" => resolve_line(related, lines)
    }
    |> reject_nil_values()
  end

  defp format_mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp format_mfa(nil), do: nil

  # Most precise anchor wins, same as the anchor itself.
  defp resolve_line(_anchored, nil), do: nil

  defp resolve_line(%{instr: %Argus.InstrId{} = instr}, lines) do
    Argus.Lines.resolve(lines, instr)
  end

  defp resolve_line(%{mfa: {_m, _f, _a} = mfa}, lines) do
    Argus.Lines.resolve(lines, mfa)
  end

  defp resolve_line(_anchored, _lines), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Encodes a term to a JSON binary string using OTP's `:json` module.
  """
  @spec encode_json(term()) :: binary()
  def encode_json(term) do
    term
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @doc """
  Encodes a term to JSON and writes it atomically to `path`.

  Writes to a temporary file first, then renames to the final path to avoid
  partial writes on crash.
  """
  @spec write_json(term(), Path.t()) :: :ok | {:error, term()}
  def write_json(term, path) do
    json = encode_json(term)
    tmp_path = path <> ".tmp"
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, json),
         :ok <- File.rename(tmp_path, path) do
      :ok
    end
  end

  # Builds a single analysis entry, filtering to output relations only.
  defp build_analysis_entry(name, {:ok, result}) do
    filtered =
      result
      |> Argus.Analysis.filter_to_outputs(name)
      |> Map.reject(fn {_name, rows} -> rows == [] end)

    finding_count =
      filtered
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    %{
      "status" => "ok",
      "findings" => filtered,
      "finding_count" => finding_count
    }
  end

  defp build_analysis_entry(_name, {:error, reason}) do
    %{
      "status" => "error",
      "findings" => %{},
      "finding_count" => 0,
      "error" => inspect(reason)
    }
  end
end
