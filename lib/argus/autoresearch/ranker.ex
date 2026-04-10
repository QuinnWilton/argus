defmodule Argus.Autoresearch.Ranker do
  @moduledoc """
  Prioritizes autoresearch targets from a `Diff`.

  The scoring formula is deliberately simple for the MVP:

      score = delta_weight × severity × spread_bonus × stickiness_dampener

      delta_weight       = max(baseline_count, current_count)
      severity           = 1.0 for imprecision, 3.0 for shape-gap
      spread_bonus       = 1 + 0.1 × (projects_affected - 1)
      stickiness_dampener = 0.5 if touched in last 3 sessions, else 1.0

  Categories listed under `## Dead ends` in `.autoresearch/notes.md`
  are excluded entirely (score → 0). New categories (present in
  current but not baseline) are flagged but not ranked for the first
  iteration — the user should inspect them manually before the
  ranker picks them.

  `rank/2` returns `[%Target{}]` sorted by descending score. A
  `suggested_extractor` string is derived from a static
  category-prefix → extractor-file map so the skill can hop directly
  to the relevant source file.
  """

  alias Argus.Autoresearch.Diff
  alias Argus.Autoresearch.Diff.{CategoryDelta, GapDelta}

  defmodule Target do
    @moduledoc """
    A single ranking target the LLM should consider working on.

    `rationale` is a one-line human-readable explanation of why this
    target ranked where it did. Designed for direct inclusion in the
    skill's proposal prompt.
    """

    @type t :: %__MODULE__{
            kind: :imprecision | :shape_gap,
            category: String.t(),
            score: float(),
            baseline: non_neg_integer(),
            current: non_neg_integer(),
            delta: integer(),
            projects_affected: non_neg_integer(),
            suggested_extractor: String.t() | nil,
            sample_funcs: [String.t()],
            rationale: String.t()
          }

    defstruct kind: :imprecision,
              category: nil,
              score: 0.0,
              baseline: 0,
              current: 0,
              delta: 0,
              projects_affected: 0,
              suggested_extractor: nil,
              sample_funcs: [],
              rationale: ""
  end

  @imprecision_severity 1.0
  @shape_gap_severity 3.0

  # Category prefix → extractor source file. Picked statically so the
  # skill doesn't need runtime introspection to know where to start
  # reading. Ordered longest-prefix-first so e.g. "statem_" resolves
  # before any shorter matches.
  @extractor_map [
    {"statem_", "lib/argus/extractors/gen_statem.ex"},
    {"gen_event_", "lib/argus/extractors/gen_event.ex"},
    {"genserver_", "lib/argus/extractors/otp.ex"},
    {"gen_server_", "lib/argus/extractors/process_registry.ex"},
    {"process_link_", "lib/argus/extractors/otp.ex"},
    {"process_register_", "lib/argus/extractors/process_registry.ex"},
    {"delayed_", "lib/argus/extractors/otp.ex"},
    {"deferred_reply_", "lib/argus/extractors/otp.ex"},
    {"sync_call_", "lib/argus/extractors/otp.ex"},
    {"dynamic_supervisor_", "lib/argus/extractors/supervision.ex"},
    {"supervisor_", "lib/argus/extractors/supervision.ex"},
    {"registry_op_", "lib/argus/extractors/process_registry.ex"},
    {"via_tuple_", "lib/argus/extractors/process_registry.ex"},
    {"whereis_", "lib/argus/extractors/process_registry.ex"},
    {"ets_", "lib/argus/extractors/ets.ex"},
    {"rpc_", "lib/argus/extractors/distributed.ex"},
    {"global_", "lib/argus/extractors/distributed.ex"},
    {"exit_call_", "lib/argus/extractors/error_handling.ex"},
    {"trap_exit_", "lib/argus/extractors/error_handling.ex"},
    {"ignored_result_", "lib/argus/extractors/error_handling.ex"},
    {"unsafe_deserialization_", "lib/argus/extractors/atom_safety.ex"},
    # Shape-gap relations map to the extractor that produces the
    # underlying fact the shape-gap rule depends on.
    {"coverage_supervisor_", "lib/argus/extractors/supervision.ex"},
    {"coverage_genserver_", "lib/argus/extractors/otp.ex"},
    {"coverage_ets_", "lib/argus/extractors/ets.ex"},
    {"coverage_statem_", "lib/argus/extractors/gen_statem.ex"},
    {"coverage_named_process_", "lib/argus/extractors/process_registry.ex"}
  ]

  @doc """
  Ranks all deltas in a diff and returns a list of `%Target{}`s
  sorted by descending score.

  Options:
  - `:dead_ends` — list of category/relation names to exclude
    (parsed from notes.md by `parse_dead_ends/1`)
  - `:recent_categories` — list of categories touched in recent
    sessions (used for the stickiness dampener)
  - `:limit` — maximum number of targets to return (default: all)
  - `:include_unchanged` — if true, also rank unchanged categories
    (useful when there's no meaningful diff to drive the initial
    iteration). Default: false.
  """
  @spec rank(Diff.t(), keyword()) :: [Target.t()]
  def rank(%Diff{} = diff, opts \\ []) do
    dead_ends = Keyword.get(opts, :dead_ends, [])
    recent = Keyword.get(opts, :recent_categories, [])
    limit = Keyword.get(opts, :limit)
    include_unchanged = Keyword.get(opts, :include_unchanged, false)

    dead_set = MapSet.new(dead_ends)
    recent_set = MapSet.new(recent)

    imprecision_targets =
      diff.imprecision
      |> Enum.reject(&skip_delta?(&1, dead_set, include_unchanged))
      |> Enum.map(&build_imprecision_target(&1, recent_set))

    shape_gap_targets =
      diff.shape_gaps
      |> Enum.reject(&skip_delta?(&1, dead_set, include_unchanged))
      |> Enum.map(&build_shape_gap_target(&1, recent_set))

    (imprecision_targets ++ shape_gap_targets)
    |> Enum.sort_by(& &1.score, :desc)
    |> maybe_take(limit)
  end

  @doc """
  Parses the `## Dead ends` section of `.autoresearch/notes.md` and
  returns a list of category names that should be excluded from
  ranking.

  The parser is intentionally forgiving: it scans for lines starting
  with `` - `<category>` `` (markdown bullet with backticked category
  name) under the `## Dead ends` heading, and stops at the next
  `##` heading. Anything not matching that shape is ignored.
  """
  @spec parse_dead_ends(String.t()) :: [String.t()]
  def parse_dead_ends(notes_content) when is_binary(notes_content) do
    notes_content
    |> String.split("\n")
    |> Enum.reduce({:before, []}, fn
      "## Dead ends" <> _, {:before, acc} ->
        {:in_dead_ends, acc}

      "## " <> _, {:in_dead_ends, acc} ->
        {:after, acc}

      line, {:in_dead_ends, acc} ->
        case extract_category(line) do
          nil -> {:in_dead_ends, acc}
          category -> {:in_dead_ends, [category | acc]}
        end

      _line, state ->
        state
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  Returns category names from the most recent N `attempt_start`
  events in the session log. Used to populate the stickiness
  dampener in `rank/2`.

  `events` is the raw session event list (as returned by
  `Session.recent/2` or `Session.all/1`). Events of other types are
  ignored.
  """
  @spec recent_categories([map()], non_neg_integer()) :: [String.t()]
  def recent_categories(events, limit \\ 3) do
    events
    |> Enum.filter(fn ev -> Map.get(ev, "event") == "attempt_start" end)
    |> Enum.reverse()
    |> Enum.take(limit)
    |> Enum.map(fn ev -> Map.get(ev, "target") end)
    |> Enum.reject(&is_nil/1)
  end

  # ── Target construction ──────────────────────────────────────────────

  defp skip_delta?(%CategoryDelta{} = d, dead_set, include_unchanged) do
    MapSet.member?(dead_set, d.category) or
      (not include_unchanged and d.delta == 0) or
      d.status == :new
  end

  defp skip_delta?(%GapDelta{} = d, dead_set, include_unchanged) do
    MapSet.member?(dead_set, d.relation) or
      (not include_unchanged and d.delta == 0) or
      d.status == :new
  end

  defp build_imprecision_target(%CategoryDelta{} = delta, recent_set) do
    projects_affected = map_size(delta.by_project)
    delta_weight = max(delta.baseline, delta.current)
    stickiness = if MapSet.member?(recent_set, delta.category), do: 0.5, else: 1.0
    spread_bonus = 1.0 + 0.1 * max(projects_affected - 1, 0)

    score = delta_weight * @imprecision_severity * spread_bonus * stickiness

    %Target{
      kind: :imprecision,
      category: delta.category,
      score: score,
      baseline: delta.baseline,
      current: delta.current,
      delta: delta.delta,
      projects_affected: projects_affected,
      suggested_extractor: lookup_extractor(delta.category),
      sample_funcs: delta.sample_funcs,
      rationale: imprecision_rationale(delta, projects_affected, stickiness)
    }
  end

  defp build_shape_gap_target(%GapDelta{} = delta, recent_set) do
    projects_affected = map_size(delta.by_project)
    delta_weight = max(delta.baseline, delta.current)
    stickiness = if MapSet.member?(recent_set, delta.relation), do: 0.5, else: 1.0
    spread_bonus = 1.0 + 0.1 * max(projects_affected - 1, 0)

    score = delta_weight * @shape_gap_severity * spread_bonus * stickiness

    %Target{
      kind: :shape_gap,
      category: delta.relation,
      score: score,
      baseline: delta.baseline,
      current: delta.current,
      delta: delta.delta,
      projects_affected: projects_affected,
      suggested_extractor: lookup_extractor(delta.relation),
      sample_funcs: [],
      rationale: shape_gap_rationale(delta, projects_affected, stickiness)
    }
  end

  defp imprecision_rationale(delta, projects_affected, stickiness) do
    base = "#{delta.current} imprecision events across #{projects_affected} project(s)"

    modifier =
      cond do
        delta.delta < 0 -> ", improved by #{abs(delta.delta)}"
        delta.delta > 0 -> ", regressed by #{delta.delta}"
        true -> ""
      end

    stickiness_note = if stickiness < 1.0, do: " [touched recently]", else: ""
    base <> modifier <> stickiness_note
  end

  defp shape_gap_rationale(delta, projects_affected, stickiness) do
    base = "#{delta.current} shape-gap rows across #{projects_affected} project(s)"

    modifier =
      cond do
        delta.delta < 0 -> ", improved by #{abs(delta.delta)}"
        delta.delta > 0 -> ", regressed by #{delta.delta}"
        true -> ""
      end

    stickiness_note = if stickiness < 1.0, do: " [touched recently]", else: ""
    base <> modifier <> stickiness_note
  end

  defp lookup_extractor(category_or_relation) do
    Enum.find_value(@extractor_map, fn {prefix, path} ->
      if String.starts_with?(category_or_relation, prefix), do: path, else: nil
    end)
  end

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, n) when is_integer(n) and n > 0, do: Enum.take(list, n)

  # Match `- `category`` or `- `category`: reason` at start of line
  # (with optional leading spaces for nested bullets).
  defp extract_category(line) do
    case Regex.run(~r/^\s*-\s*`([^`]+)`/, line) do
      [_, category] -> category
      _ -> nil
    end
  end
end
