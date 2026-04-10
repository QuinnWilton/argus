defmodule Argus.Autoresearch.Diff do
  @moduledoc """
  Compute structural diffs between two `Argus.Autoresearch.Snapshot`s.

  The diff is how the autoresearch loop knows whether a change helped.
  A `%Diff{}` records per-category and per-shape-gap deltas, splits
  them into `improvements` and `regressions` views, and flags
  categories that appeared or disappeared between the two snapshots.

  `Diff.compute/2` refuses to compare snapshots with mismatched schema
  versions — if the coverage analysis added or renamed a relation
  since the baseline was captured, the user must rebaseline.

  ## Scoring and net totals

  `net_total` is the sum of all imprecision deltas (baseline total -
  current total). Negative = net improvement. Shape-gap deltas are
  tracked separately; they're not part of `net_total` because a
  single shape-gap row implies an entire class of missing extraction,
  which is a different currency from imprecision counts.
  """

  alias Argus.Autoresearch.Snapshot

  defmodule CategoryDelta do
    @moduledoc """
    Per-category imprecision delta.

    `status` is `:improved | :regressed | :unchanged | :new | :removed`.
    `:new` means the category had no rows in the baseline (even if the
    category itself existed). `:removed` means no rows in the current.
    """

    @type status :: :improved | :regressed | :unchanged | :new | :removed

    @type t :: %__MODULE__{
            category: String.t(),
            baseline: non_neg_integer(),
            current: non_neg_integer(),
            delta: integer(),
            by_project: %{String.t() => integer()},
            status: status(),
            sample_funcs: [String.t()]
          }

    defstruct category: nil,
              baseline: 0,
              current: 0,
              delta: 0,
              by_project: %{},
              status: :unchanged,
              sample_funcs: []
  end

  defmodule GapDelta do
    @moduledoc """
    Per-shape-gap relation delta.

    Shape gaps carry the full row list in both snapshots (they're
    small), so the delta can also surface exactly which rows appeared
    or disappeared.
    """

    @type t :: %__MODULE__{
            relation: String.t(),
            baseline: non_neg_integer(),
            current: non_neg_integer(),
            delta: integer(),
            by_project: %{String.t() => integer()},
            added_rows: [[String.t()]],
            removed_rows: [[String.t()]],
            status: CategoryDelta.status()
          }

    defstruct relation: nil,
              baseline: 0,
              current: 0,
              delta: 0,
              by_project: %{},
              added_rows: [],
              removed_rows: [],
              status: :unchanged
  end

  @type t :: %__MODULE__{
          schema_version: non_neg_integer(),
          baseline_sha: String.t() | nil,
          current_sha: String.t() | nil,
          tier: String.t() | nil,
          imprecision: [CategoryDelta.t()],
          shape_gaps: [GapDelta.t()],
          new_categories: [String.t()],
          removed_categories: [String.t()],
          improvements: [CategoryDelta.t() | GapDelta.t()],
          regressions: [CategoryDelta.t() | GapDelta.t()],
          net_total: integer()
        }

  defstruct schema_version: 1,
            baseline_sha: nil,
            current_sha: nil,
            tier: nil,
            imprecision: [],
            shape_gaps: [],
            new_categories: [],
            removed_categories: [],
            improvements: [],
            regressions: [],
            net_total: 0

  @doc """
  Computes the diff between two snapshots.

  Returns `{:ok, %Diff{}}` on success, or `{:error, :schema_mismatch}`
  if the snapshots have incompatible schema versions.
  """
  @spec compute(Snapshot.t(), Snapshot.t()) :: {:ok, t()} | {:error, :schema_mismatch}
  def compute(%Snapshot{} = baseline, %Snapshot{} = current) do
    if baseline.schema_version != current.schema_version do
      {:error, :schema_mismatch}
    else
      imprecision_deltas = imprecision_diff(baseline, current)
      shape_gap_deltas = shape_gap_diff(baseline, current)

      {new_cats, removed_cats} = category_changes(baseline, current)

      {improvements, regressions} = partition(imprecision_deltas ++ shape_gap_deltas)

      net_total =
        imprecision_deltas
        |> Enum.map(& &1.delta)
        |> Enum.sum()

      {:ok,
       %__MODULE__{
         schema_version: baseline.schema_version,
         baseline_sha: baseline.argus_git_sha,
         current_sha: current.argus_git_sha,
         tier: current.tier,
         imprecision: Enum.sort_by(imprecision_deltas, & &1.category),
         shape_gaps: Enum.sort_by(shape_gap_deltas, & &1.relation),
         new_categories: new_cats,
         removed_categories: removed_cats,
         improvements: Enum.sort_by(improvements, &magnitude/1, :desc),
         regressions: Enum.sort_by(regressions, &magnitude/1, :desc),
         net_total: net_total
       }}
    end
  end

  # ── Imprecision diff ─────────────────────────────────────────────────

  defp imprecision_diff(baseline, current) do
    base = baseline.counts.imprecision_event
    curr = current.counts.imprecision_event

    all_categories = MapSet.union(keyset(base), keyset(curr))

    Enum.map(all_categories, fn category ->
      build_category_delta(category, Map.get(base, category), Map.get(curr, category))
    end)
  end

  defp build_category_delta(category, nil, curr_agg) do
    %CategoryDelta{
      category: category,
      baseline: 0,
      current: curr_agg.total,
      delta: curr_agg.total,
      by_project: sign_project_deltas(%{}, curr_agg.by_project),
      status: :new,
      sample_funcs: curr_agg.sample_funcs
    }
  end

  defp build_category_delta(category, base_agg, nil) do
    %CategoryDelta{
      category: category,
      baseline: base_agg.total,
      current: 0,
      delta: -base_agg.total,
      by_project: sign_project_deltas(base_agg.by_project, %{}),
      status: :removed,
      sample_funcs: base_agg.sample_funcs
    }
  end

  defp build_category_delta(category, base_agg, curr_agg) do
    delta = curr_agg.total - base_agg.total

    %CategoryDelta{
      category: category,
      baseline: base_agg.total,
      current: curr_agg.total,
      delta: delta,
      by_project: sign_project_deltas(base_agg.by_project, curr_agg.by_project),
      status: category_status(delta),
      sample_funcs: curr_agg.sample_funcs
    }
  end

  defp category_status(0), do: :unchanged
  defp category_status(delta) when delta < 0, do: :improved
  defp category_status(_delta), do: :regressed

  # Compute per-project delta (current - baseline) for every project
  # present in either side. Zero-delta projects are dropped so the map
  # stays focused on what changed.
  defp sign_project_deltas(base, curr) do
    projects = MapSet.union(keyset(base), keyset(curr))

    projects
    |> Enum.map(fn project ->
      {project, Map.get(curr, project, 0) - Map.get(base, project, 0)}
    end)
    |> Enum.reject(fn {_, delta} -> delta == 0 end)
    |> Map.new()
  end

  # ── Shape-gap diff ───────────────────────────────────────────────────

  defp shape_gap_diff(baseline, current) do
    base = baseline.counts.shape_gaps
    curr = current.counts.shape_gaps

    all_relations = MapSet.union(keyset(base), keyset(curr))

    Enum.map(all_relations, fn relation ->
      build_gap_delta(relation, Map.get(base, relation), Map.get(curr, relation))
    end)
  end

  defp build_gap_delta(relation, nil, curr_agg) do
    %GapDelta{
      relation: relation,
      baseline: 0,
      current: curr_agg.total,
      delta: curr_agg.total,
      by_project: sign_project_deltas(%{}, curr_agg.by_project),
      added_rows: curr_agg.rows,
      removed_rows: [],
      status: :new
    }
  end

  defp build_gap_delta(relation, base_agg, nil) do
    %GapDelta{
      relation: relation,
      baseline: base_agg.total,
      current: 0,
      delta: -base_agg.total,
      by_project: sign_project_deltas(base_agg.by_project, %{}),
      added_rows: [],
      removed_rows: base_agg.rows,
      status: :removed
    }
  end

  defp build_gap_delta(relation, base_agg, curr_agg) do
    delta = curr_agg.total - base_agg.total
    base_set = MapSet.new(base_agg.rows)
    curr_set = MapSet.new(curr_agg.rows)

    added = curr_set |> MapSet.difference(base_set) |> Enum.sort()
    removed = base_set |> MapSet.difference(curr_set) |> Enum.sort()

    %GapDelta{
      relation: relation,
      baseline: base_agg.total,
      current: curr_agg.total,
      delta: delta,
      by_project: sign_project_deltas(base_agg.by_project, curr_agg.by_project),
      added_rows: added,
      removed_rows: removed,
      status: category_status(delta)
    }
  end

  # ── Category change tracking ─────────────────────────────────────────

  defp category_changes(baseline, current) do
    base_keys = keyset(baseline.counts.imprecision_event)
    curr_keys = keyset(current.counts.imprecision_event)

    new = curr_keys |> MapSet.difference(base_keys) |> Enum.sort()
    removed = base_keys |> MapSet.difference(curr_keys) |> Enum.sort()

    {new, removed}
  end

  # ── Partitioning improvements and regressions ───────────────────────

  defp partition(deltas) do
    Enum.split_with(deltas, &(&1.delta < 0))
    |> then(fn {improved, rest} ->
      regressed = Enum.filter(rest, &(&1.delta > 0))
      {improved, regressed}
    end)
  end

  defp magnitude(%CategoryDelta{delta: d}), do: abs(d)
  defp magnitude(%GapDelta{delta: d}), do: abs(d)

  defp keyset(map) when is_map(map), do: map |> Map.keys() |> MapSet.new()
end
