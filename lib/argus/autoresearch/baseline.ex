defmodule Argus.Autoresearch.Baseline do
  @moduledoc """
  Committed baseline store.

  The baseline is the "previous best known state" that new measurements
  diff against. It lives at `.autoresearch/baseline/` (committed to
  the repo) and consists of:

  - `snapshot.json` — canonicalized `Argus.Autoresearch.Snapshot`
  - `metadata.json` — provenance: git sha, tier, argus version, timestamp
  - `canary_correctness.json` — finding counts for the canary project
    across the default correctness analyses (regression guard)

  `promote/2` atomically replaces the baseline with a new snapshot
  (typically called from `accept`). `read/1` loads it back.
  """

  alias Argus.Autoresearch.Snapshot
  alias Argus.Report

  @type metadata :: %{
          argus_git_sha: String.t() | nil,
          tier: String.t() | nil,
          argus_version: String.t() | nil,
          created_at: String.t(),
          note: String.t() | nil
        }

  @default_dir ".autoresearch/baseline"

  @doc """
  Returns the default baseline directory (relative to repo root).
  """
  @spec default_dir() :: Path.t()
  def default_dir, do: @default_dir

  @doc "Path to the snapshot file inside a baseline directory."
  @spec snapshot_path(Path.t()) :: Path.t()
  def snapshot_path(dir \\ @default_dir), do: Path.join(dir, "snapshot.json")

  @doc "Path to the metadata file inside a baseline directory."
  @spec metadata_path(Path.t()) :: Path.t()
  def metadata_path(dir \\ @default_dir), do: Path.join(dir, "metadata.json")

  @doc "Path to the canary correctness fixture file."
  @spec canary_path(Path.t()) :: Path.t()
  def canary_path(dir \\ @default_dir), do: Path.join(dir, "canary_correctness.json")

  @doc """
  Returns true if a baseline snapshot exists at `dir`.
  """
  @spec exists?(Path.t()) :: boolean()
  def exists?(dir \\ @default_dir), do: File.exists?(snapshot_path(dir))

  @doc """
  Reads the baseline snapshot. Returns `{:error, :no_baseline}` if
  the snapshot file doesn't exist.
  """
  @spec read(Path.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def read(dir \\ @default_dir) do
    path = snapshot_path(dir)

    if File.exists?(path) do
      Snapshot.read(path)
    else
      {:error, :no_baseline}
    end
  end

  @doc """
  Reads the baseline metadata (or `{:error, :no_baseline}`).
  """
  @spec metadata(Path.t()) :: {:ok, metadata()} | {:error, term()}
  def metadata(dir \\ @default_dir) do
    path = metadata_path(dir)

    with true <- File.exists?(path) || {:error, :no_baseline},
         {:ok, content} <- File.read(path),
         {:ok, json} <- decode_json(content) do
      {:ok, normalize_metadata(json)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_baseline}
    end
  end

  @doc """
  Promotes a snapshot to the committed baseline, replacing whatever
  was there before. Writes both `snapshot.json` and a fresh
  `metadata.json`.

  Options:
  - `:dir` — override the baseline directory (default: `.autoresearch/baseline`)
  - `:argus_version` — string to record in metadata (default: read from mix.exs)
  - `:note` — free-form note appended to metadata (e.g. "rebaseline after fix X")
  """
  @spec promote(Snapshot.t(), keyword()) :: :ok | {:error, term()}
  def promote(%Snapshot{} = snapshot, opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    note = Keyword.get(opts, :note)

    metadata = %{
      "argus_git_sha" => snapshot.argus_git_sha,
      "tier" => snapshot.tier,
      "argus_version" => Keyword.get_lazy(opts, :argus_version, &argus_version/0),
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "note" => note
    }

    with :ok <- File.mkdir_p(dir),
         :ok <- write_snapshot(snapshot, dir),
         :ok <- Report.write_json(metadata, metadata_path(dir)) do
      :ok
    end
  end

  @doc """
  Writes the canary correctness fixture file. Called during initial
  baseline capture and after explicit rebaselines.

  `fixture` is a map of `analysis_name => finding_count` for the
  canary project. Kept simple on purpose — the point is to detect
  drift, not to reproduce exact findings.
  """
  @spec write_canary(map(), Path.t()) :: :ok | {:error, term()}
  def write_canary(fixture, dir \\ @default_dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- Report.write_json(fixture, canary_path(dir)) do
      :ok
    end
  end

  @doc """
  Reads the canary correctness fixture. Returns `{:error, :no_canary}`
  if the file doesn't exist.
  """
  @spec read_canary(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_canary(dir \\ @default_dir) do
    path = canary_path(dir)

    if File.exists?(path) do
      with {:ok, content} <- File.read(path),
           {:ok, json} <- decode_json(content) do
        {:ok, json}
      end
    else
      {:error, :no_canary}
    end
  end

  defp write_snapshot(snapshot, dir) do
    try do
      Snapshot.write!(snapshot, snapshot_path(dir))
      :ok
    rescue
      e -> {:error, {:write_failed, Exception.message(e)}}
    end
  end

  defp normalize_metadata(json) when is_map(json) do
    %{
      argus_git_sha: Map.get(json, "argus_git_sha"),
      tier: Map.get(json, "tier"),
      argus_version: Map.get(json, "argus_version"),
      created_at: Map.get(json, "created_at"),
      note: Map.get(json, "note")
    }
  end

  defp argus_version do
    case :application.get_key(:argus, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "unknown"
    end
  end

  defp decode_json(content) do
    try do
      {:ok, :json.decode(content)}
    rescue
      e -> {:error, {:decode_failed, Exception.message(e)}}
    end
  end
end
