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
  """
  @spec build_project_report(map(), [{atom(), {:ok, map()} | {:error, term()}}]) :: map()
  def build_project_report(meta, analysis_results) do
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

    %{
      "meta" => meta,
      "analyses" => analyses,
      "summary" => %{
        "total_findings" => total_findings,
        "analyses_run" => map_size(analyses),
        "analyses_failed" => analyses_failed
      }
    }
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
