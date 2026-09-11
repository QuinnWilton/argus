defmodule Argus.Autoresearch.Snapshot do
  @moduledoc """
  Canonicalized snapshot of a coverage analysis run across a corpus.

  A `Snapshot` is the reduced form of one or more per-project coverage
  reports that the autoresearch loop diffs against a baseline. It is
  **load-bearing for the diff loop**: if two snapshots produced from the
  same inputs don't compare equal, the whole diff pipeline reports
  spurious churn.

  ## Canonicalization

  `from_reports/2` takes a list of `%{project => report}` tuples (as
  produced by `Argus.Report.build_project_report/2`) and:

  1. Drops the nondeterministic `meta.timestamp` and `meta.duration_ms`
     fields — they change on every run and would swamp the diff.
  2. Reduces `imprecision_event` rows to per-category aggregates with
     `total`, `by_project`, `by_relation`, `by_reason`, and the first
     ten `sample_funcs` (lexicographically sorted). The raw rows stay
     in the per-project reports for drill-down; they don't belong in
     the snapshot.
  3. Stores shape-gap rows (e.g. `coverage_supervisor_no_children`) in
     full — they're O(tens), small enough to diff exactly.
  4. Sorts every list (categories, projects, funcs, rows) so the
     snapshot is `==`-comparable across runs and `jq -S` diffs are
     empty.

  ## Shape version

  The `schema_version` field locks the snapshot format. Increment it
  when the coverage analysis adds/renames an output relation or when
  the snapshot layout itself changes. `Argus.Autoresearch.Diff` refuses
  to compare snapshots across different schema versions.
  """

  alias Argus.Report

  @schema_version 1

  # Known coverage shape-gap relations. Listed explicitly (rather than
  # derived at runtime from the analysis) so the snapshot shape is
  # stable even if new relations are added without bumping
  # @schema_version intentionally.
  @shape_gap_relations ~w(
    coverage_supervisor_no_children
    coverage_genserver_isolated
    coverage_ets_unused
    coverage_named_process_unreachable
  )

  @imprecision_relation "imprecision_event"

  @type project_name :: String.t()
  @type category :: String.t()
  @type imprecision_aggregate :: %{
          total: non_neg_integer(),
          by_project: %{project_name() => non_neg_integer()},
          by_relation: %{String.t() => non_neg_integer()},
          by_reason: %{String.t() => non_neg_integer()},
          sample_funcs: [String.t()]
        }
  @type shape_gap_aggregate :: %{
          total: non_neg_integer(),
          by_project: %{project_name() => non_neg_integer()},
          rows: [[String.t()]]
        }

  @type t :: %__MODULE__{
          schema_version: non_neg_integer(),
          tier: String.t() | nil,
          argus_git_sha: String.t() | nil,
          projects: [project_name()],
          counts: %{
            imprecision_event: %{category() => imprecision_aggregate()},
            shape_gaps: %{String.t() => shape_gap_aggregate()}
          }
        }

  defstruct schema_version: @schema_version,
            tier: nil,
            argus_git_sha: nil,
            projects: [],
            counts: %{imprecision_event: %{}, shape_gaps: %{}}

  @doc """
  Returns the canonical schema version.
  """
  @spec schema_version() :: non_neg_integer()
  def schema_version, do: @schema_version

  @doc """
  Builds a canonicalized snapshot from per-project coverage reports.

  `project_reports` is a list of `{project_name, report}` tuples where
  `report` is the map produced by `Argus.Report.build_project_report/2`
  (or loaded from a `results.json` file).

  Options:

  - `:tier` — the corpus tier name (e.g. `"fast"`).
  - `:argus_git_sha` — the argus git SHA this snapshot was produced
    from. Stored for provenance; not used in comparison.
  - `:schema_version` — override the default schema version (useful
    only in tests).
  """
  @spec from_reports([{project_name(), map()}], keyword()) :: t()
  def from_reports(project_reports, opts \\ []) when is_list(project_reports) do
    schema_version = Keyword.get(opts, :schema_version, @schema_version)
    tier = Keyword.get(opts, :tier)
    argus_git_sha = Keyword.get(opts, :argus_git_sha)

    projects =
      project_reports
      |> Enum.map(fn {name, _report} -> name end)
      |> Enum.sort()

    imprecision_counts = build_imprecision_counts(project_reports)
    shape_gap_counts = build_shape_gap_counts(project_reports)

    %__MODULE__{
      schema_version: schema_version,
      tier: tier,
      argus_git_sha: argus_git_sha,
      projects: projects,
      counts: %{
        imprecision_event: imprecision_counts,
        shape_gaps: shape_gap_counts
      }
    }
  end

  @doc """
  Serializes a snapshot to a JSON-ready map (string keys throughout,
  with lists sorted for deterministic output).

  Pair with `Argus.Report.encode_json/1` and `Argus.Report.write_json/2`
  to write it to disk atomically.

  Nil-valued top-level fields (`tier`, `argus_git_sha`) are omitted
  rather than serialized — OTP's `:json` encoder turns atom `nil` into
  the string `"nil"` rather than JSON null, so omission is the safe
  choice and keeps the on-disk shape closer to standard JSON.
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = snapshot) do
    base = %{
      "schema_version" => snapshot.schema_version,
      "projects" => snapshot.projects,
      "counts" => %{
        "imprecision_event" => imprecision_to_json(snapshot.counts.imprecision_event),
        "shape_gaps" => shape_gaps_to_json(snapshot.counts.shape_gaps)
      }
    }

    base
    |> put_if_present("tier", snapshot.tier)
    |> put_if_present("argus_git_sha", snapshot.argus_git_sha)
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Parses a snapshot from a JSON-decoded map (the inverse of `to_json/1`).

  Returns `{:ok, snapshot}` or `{:error, reason}` on malformed input.
  """
  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_map(json) do
    with {:ok, schema_version} <- fetch_int(json, "schema_version"),
         {:ok, projects} <- fetch_list(json, "projects"),
         {:ok, counts} <- fetch_map(json, "counts"),
         {:ok, imprecision_raw} <- fetch_map(counts, "imprecision_event"),
         {:ok, shape_gaps_raw} <- fetch_map(counts, "shape_gaps") do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         tier: json["tier"],
         argus_git_sha: json["argus_git_sha"],
         projects: projects,
         counts: %{
           imprecision_event: imprecision_from_json(imprecision_raw),
           shape_gaps: shape_gaps_from_json(shape_gaps_raw)
         }
       }}
    end
  end

  @doc """
  Writes a snapshot to disk as canonical JSON using
  `Argus.Report.write_json/2` (atomic write via tmp+rename).
  """
  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{} = snapshot, path) do
    case Report.write_json(to_json(snapshot), path) do
      :ok -> :ok
      {:error, reason} -> raise "failed to write snapshot to #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Reads a snapshot from disk.
  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- decode_json(content) do
      from_json(json)
    end
  end

  # ── Imprecision aggregation ──────────────────────────────────────────

  defp build_imprecision_counts(project_reports) do
    project_reports
    |> Enum.reduce(%{}, fn {project, report}, acc ->
      rows = coverage_rows(report, @imprecision_relation)
      aggregate_imprecision(acc, project, rows)
    end)
    |> Map.new(fn {category, agg} ->
      {category, finalize_imprecision(agg)}
    end)
  end

  # Walks an imprecision_event row list, adding to a per-category
  # accumulator keyed by the category column (column 0).
  defp aggregate_imprecision(acc, project, rows) do
    Enum.reduce(rows, acc, fn row, inner ->
      case row do
        [category, func, relation, reason] ->
          update_imprecision(inner, category, project, func, relation, reason)

        _ ->
          inner
      end
    end)
  end

  defp update_imprecision(acc, category, project, func, relation, reason) do
    Map.update(
      acc,
      category,
      initial_imprecision(project, func, relation, reason),
      fn existing ->
        %{
          total: existing.total + 1,
          by_project: increment(existing.by_project, project),
          by_relation: increment(existing.by_relation, relation),
          by_reason: increment(existing.by_reason, reason),
          funcs_seen: MapSet.put(existing.funcs_seen, func)
        }
      end
    )
  end

  defp initial_imprecision(project, func, relation, reason) do
    %{
      total: 1,
      by_project: %{project => 1},
      by_relation: %{relation => 1},
      by_reason: %{reason => 1},
      funcs_seen: MapSet.new([func])
    }
  end

  # Replace the MapSet with a sorted list of the first 10 funcs.
  # Dropping the intermediate set here means `to_json/1` doesn't have to
  # know about the accumulator shape.
  defp finalize_imprecision(agg) do
    %{
      total: agg.total,
      by_project: agg.by_project,
      by_relation: agg.by_relation,
      by_reason: agg.by_reason,
      sample_funcs: agg.funcs_seen |> MapSet.to_list() |> Enum.sort() |> Enum.take(10)
    }
  end

  # ── Shape-gap aggregation ────────────────────────────────────────────

  defp build_shape_gap_counts(project_reports) do
    Enum.reduce(@shape_gap_relations, %{}, fn relation, acc ->
      {total_rows, by_project} = collect_shape_gap(project_reports, relation)

      if total_rows == [] do
        acc
      else
        Map.put(acc, relation, %{
          total: length(total_rows),
          by_project: by_project,
          rows: total_rows
        })
      end
    end)
  end

  defp collect_shape_gap(project_reports, relation) do
    {rows, by_project} =
      Enum.reduce(project_reports, {[], %{}}, fn {project, report}, {acc_rows, acc_proj} ->
        rows = coverage_rows(report, relation)
        {rows ++ acc_rows, update_project_count(acc_proj, project, length(rows))}
      end)

    sorted_unique_rows = rows |> Enum.uniq() |> Enum.sort()
    {sorted_unique_rows, by_project}
  end

  defp update_project_count(map, _project, 0), do: map
  defp update_project_count(map, project, count), do: Map.put(map, project, count)

  # ── Report navigation ────────────────────────────────────────────────

  # Extract rows for a given coverage relation from a build_project_report
  # output. Returns [] if the relation is absent (e.g. the project had
  # no ETS unused entries).
  defp coverage_rows(report, relation) do
    with %{"analyses" => analyses} <- report,
         %{"coverage" => coverage} <- analyses,
         %{"findings" => findings} <- coverage,
         rows when is_list(rows) <- Map.get(findings, relation, []) do
      rows
    else
      _ -> []
    end
  end

  defp increment(map, key), do: Map.update(map, key, 1, &(&1 + 1))

  # ── JSON conversion ──────────────────────────────────────────────────

  defp imprecision_to_json(imprecision_map) do
    imprecision_map
    |> Enum.sort_by(fn {cat, _} -> cat end)
    |> Map.new(fn {category, agg} ->
      {category,
       %{
         "total" => agg.total,
         "by_project" => sorted_map(agg.by_project),
         "by_relation" => sorted_map(agg.by_relation),
         "by_reason" => sorted_map(agg.by_reason),
         "sample_funcs" => agg.sample_funcs
       }}
    end)
  end

  defp shape_gaps_to_json(shape_gaps) do
    shape_gaps
    |> Enum.sort_by(fn {rel, _} -> rel end)
    |> Map.new(fn {relation, agg} ->
      {relation,
       %{
         "total" => agg.total,
         "by_project" => sorted_map(agg.by_project),
         "rows" => agg.rows
       }}
    end)
  end

  # Maps with string keys are already unordered in memory, but JSON
  # encoders may preserve insertion order. Building from a sorted
  # list guarantees deterministic on-disk output.
  defp sorted_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Map.new()
  end

  defp imprecision_from_json(raw) do
    Map.new(raw, fn {category, entry} ->
      {category,
       %{
         total: Map.fetch!(entry, "total"),
         by_project: Map.get(entry, "by_project", %{}),
         by_relation: Map.get(entry, "by_relation", %{}),
         by_reason: Map.get(entry, "by_reason", %{}),
         sample_funcs: Map.get(entry, "sample_funcs", [])
       }}
    end)
  end

  defp shape_gaps_from_json(raw) do
    Map.new(raw, fn {relation, entry} ->
      {relation,
       %{
         total: Map.fetch!(entry, "total"),
         by_project: Map.get(entry, "by_project", %{}),
         rows: Map.get(entry, "rows", [])
       }}
    end)
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  defp fetch_int(map, key) do
    case Map.fetch(map, key) do
      {:ok, n} when is_integer(n) -> {:ok, n}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_list(map, key) do
    case Map.fetch(map, key) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp fetch_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp decode_json(content) do
    {:ok, :json.decode(content)}
  rescue
    e -> {:error, {:decode_failed, e}}
  end
end
