defmodule Argus.Autoresearch.RankerTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.{Diff, Ranker}
  alias Argus.Autoresearch.Diff.{CategoryDelta, GapDelta}
  alias Argus.Autoresearch.Ranker.Target

  defp diff_with(imprecision, shape_gaps \\ []) do
    %Diff{
      schema_version: 1,
      imprecision: imprecision,
      shape_gaps: shape_gaps,
      net_total: Enum.map(imprecision, & &1.delta) |> Enum.sum()
    }
  end

  defp category(name, baseline, current, by_project \\ nil) do
    delta = current - baseline
    projects = by_project || %{"p1" => delta}

    status =
      cond do
        delta < 0 -> :improved
        delta > 0 -> :regressed
        true -> :unchanged
      end

    %CategoryDelta{
      category: name,
      baseline: baseline,
      current: current,
      delta: delta,
      by_project: projects,
      status: status,
      sample_funcs: ["A:f/0", "B:g/1"]
    }
  end

  defp gap(name, baseline, current, by_project \\ nil) do
    delta = current - baseline
    projects = by_project || %{"p1" => delta}

    %GapDelta{
      relation: name,
      baseline: baseline,
      current: current,
      delta: delta,
      by_project: projects,
      added_rows: [],
      removed_rows: [],
      status: if(delta < 0, do: :improved, else: :regressed)
    }
  end

  describe "rank/2 — basic scoring" do
    test "scores imprecision by delta_weight × severity" do
      diff =
        diff_with([
          category("small", 3, 1),
          category("big", 50, 30)
        ])

      targets = Ranker.rank(diff)

      assert [%Target{category: "big"}, %Target{category: "small"}] = targets
    end

    test "shape gaps have 3× severity over imprecision" do
      diff =
        diff_with(
          [category("imp", 10, 0)],
          [gap("coverage_ets_unused", 4, 0)]
        )

      targets = Ranker.rank(diff)

      # Imprecision score: 10 * 1.0 * 1.0 * 1.0 = 10
      # Shape gap score:   4 * 3.0 * 1.0 * 1.0 = 12
      # Shape gap wins despite smaller raw count.
      assert [%Target{kind: :shape_gap}, %Target{kind: :imprecision}] = targets
    end

    test "spread_bonus rewards categories affecting multiple projects" do
      single =
        diff_with([category("solo", 10, 0, %{"p1" => -10})])

      multi =
        diff_with([
          category("spread", 10, 0, %{"p1" => -4, "p2" => -4, "p3" => -2})
        ])

      [solo_target] = Ranker.rank(single)
      [multi_target] = Ranker.rank(multi)

      # 3 projects -> 1 + 0.1 * 2 = 1.2
      assert_in_delta multi_target.score, solo_target.score * 1.2, 0.0001
    end

    test "stickiness dampener halves the score for recently-touched categories" do
      diff = diff_with([category("cat", 10, 5)])

      fresh = Ranker.rank(diff)
      recent = Ranker.rank(diff, recent_categories: ["cat"])

      assert [%Target{score: fresh_score}] = fresh
      assert [%Target{score: recent_score}] = recent
      assert_in_delta recent_score, fresh_score / 2, 0.0001
    end
  end

  describe "rank/2 — exclusions" do
    test "dead_ends categories are excluded from ranking" do
      diff =
        diff_with([
          category("dead", 100, 100),
          category("alive", 10, 5)
        ])

      targets = Ranker.rank(diff, dead_ends: ["dead"])

      assert [%Target{category: "alive"}] = targets
    end

    test "dead_ends applies to shape gaps too" do
      diff =
        diff_with(
          [],
          [gap("coverage_ets_unused", 5, 2), gap("coverage_genserver_isolated", 3, 1)]
        )

      targets = Ranker.rank(diff, dead_ends: ["coverage_ets_unused"])

      assert [%Target{category: "coverage_genserver_isolated"}] = targets
    end

    test "categories with :new status are not ranked" do
      new_delta = %CategoryDelta{
        category: "fresh",
        baseline: 0,
        current: 10,
        delta: 10,
        status: :new,
        by_project: %{"p1" => 10}
      }

      diff = diff_with([new_delta, category("existing", 5, 2)])
      targets = Ranker.rank(diff)

      assert [%Target{category: "existing"}] = targets
    end

    test "unchanged categories are dropped unless include_unchanged: true" do
      diff = diff_with([category("stable", 5, 5), category("changing", 10, 5)])

      default = Ranker.rank(diff)
      assert [%Target{category: "changing"}] = default

      with_stable = Ranker.rank(diff, include_unchanged: true)
      names = Enum.map(with_stable, & &1.category) |> Enum.sort()
      assert names == ["changing", "stable"]
    end
  end

  describe "rank/2 — suggested_extractor" do
    test "maps category prefixes to extractor files" do
      diff =
        diff_with([
          category("genserver_callee", 10, 5),
          category("ets_table_ref_op", 8, 3),
          category("supervisor_child_module", 6, 2)
        ])

      targets = Ranker.rank(diff)

      by_category = Map.new(targets, fn t -> {t.category, t.suggested_extractor} end)

      assert by_category["genserver_callee"] == "lib/argus/extractors/otp.ex"
      assert by_category["ets_table_ref_op"] == "lib/argus/extractors/ets.ex"
      assert by_category["supervisor_child_module"] == "lib/argus/extractors/supervision.ex"
    end

    test "longest-prefix match wins — gen_server_start_name routes to process_registry" do
      diff = diff_with([category("gen_server_start_name", 5, 2)])
      [target] = Ranker.rank(diff)
      assert target.suggested_extractor == "lib/argus/extractors/process_registry.ex"
    end

    test "shape-gap relations map to their underlying extractors" do
      diff =
        diff_with(
          [],
          [gap("coverage_supervisor_no_children", 3, 1)]
        )

      [target] = Ranker.rank(diff)
      assert target.suggested_extractor == "lib/argus/extractors/supervision.ex"
    end

    test "unknown category returns nil extractor" do
      diff = diff_with([category("totally_unknown_category_xyz", 5, 2)])
      [target] = Ranker.rank(diff)
      assert target.suggested_extractor == nil
    end
  end

  describe "rank/2 — limit" do
    test "limit truncates the result list" do
      diff =
        diff_with([
          category("a", 10, 5),
          category("b", 20, 10),
          category("c", 5, 2)
        ])

      assert Ranker.rank(diff) |> length() == 3
      assert Ranker.rank(diff, limit: 2) |> length() == 2
    end
  end

  describe "parse_dead_ends/1" do
    test "extracts backticked category names from the Dead ends section" do
      notes = """
      # Argus Autoresearch

      ## Wins
      - 2026-04-09 — `foo_cat`: -10 via bar

      ## Dead ends
      - `genserver_init_dynamic_args`: tried 2026-04-10, abandoned
      - `keyword_merge_resolution`: no static recovery path

      ## Parking lot
      - `other_thing`: low priority
      """

      dead_ends = Ranker.parse_dead_ends(notes)
      assert dead_ends == ["genserver_init_dynamic_args", "keyword_merge_resolution"]
    end

    test "returns [] when no Dead ends section exists" do
      notes = """
      # Notes

      ## Objective
      Reduce imprecision.
      """

      assert Ranker.parse_dead_ends(notes) == []
    end

    test "stops at next ## heading" do
      notes = """
      ## Dead ends
      - `in_dead_ends`: reason

      ## Parking lot
      - `not_in_dead_ends`: reason
      """

      assert Ranker.parse_dead_ends(notes) == ["in_dead_ends"]
    end

    test "ignores lines that don't match the expected shape" do
      notes = """
      ## Dead ends
      random text
      - not backticked: reason
      - `valid_category`: yes
      arbitrary line
      """

      assert Ranker.parse_dead_ends(notes) == ["valid_category"]
    end
  end

  describe "recent_categories/2" do
    test "extracts target fields from the last N attempt_start events" do
      events = [
        %{"event" => "measure"},
        %{"event" => "attempt_start", "target" => "first_cat"},
        %{"event" => "checks"},
        %{"event" => "attempt_start", "target" => "second_cat"},
        %{"event" => "attempt_start", "target" => "third_cat"},
        %{"event" => "attempt_start", "target" => "fourth_cat"}
      ]

      assert Ranker.recent_categories(events, 3) == ["fourth_cat", "third_cat", "second_cat"]
    end

    test "returns empty list when no attempt_start events exist" do
      assert Ranker.recent_categories([%{"event" => "measure"}]) == []
    end
  end
end
