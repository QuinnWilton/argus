defmodule Argus.Autoresearch.DiffTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.{Diff, Snapshot}
  alias Argus.Autoresearch.Diff.{CategoryDelta, GapDelta}

  # Construct snapshots directly for tests rather than going through
  # from_reports — the diff logic is pure and should be testable
  # without touching the canonicalizer.
  defp snapshot(imprecision, shape_gaps \\ %{}, opts \\ []) do
    %Snapshot{
      schema_version: Keyword.get(opts, :schema_version, Snapshot.schema_version()),
      tier: Keyword.get(opts, :tier, "fast"),
      argus_git_sha: Keyword.get(opts, :sha),
      projects: Keyword.get(opts, :projects, ["a", "b"]),
      counts: %{
        imprecision_event: imprecision,
        shape_gaps: shape_gaps
      }
    }
  end

  defp category(total, opts \\ []) do
    %{
      total: total,
      by_project: Keyword.get(opts, :by_project, %{"a" => total}),
      by_relation: Keyword.get(opts, :by_relation, %{"sync_call" => total}),
      by_reason: Keyword.get(opts, :by_reason, %{"dynamic" => total}),
      sample_funcs: Keyword.get(opts, :funcs, [])
    }
  end

  defp gap(total, rows) do
    %{
      total: total,
      by_project: %{"a" => total},
      rows: rows
    }
  end

  describe "compute/2" do
    test "reports an improved category with a negative delta" do
      base = snapshot(%{"cat" => category(10)})
      curr = snapshot(%{"cat" => category(4)})

      assert {:ok, diff} = Diff.compute(base, curr)

      assert [
               %CategoryDelta{
                 category: "cat",
                 baseline: 10,
                 current: 4,
                 delta: -6,
                 status: :improved
               }
             ] =
               diff.imprecision

      assert diff.net_total == -6
      assert length(diff.improvements) == 1
      assert diff.regressions == []
    end

    test "reports a regressed category with a positive delta" do
      base = snapshot(%{"cat" => category(4)})
      curr = snapshot(%{"cat" => category(10)})

      assert {:ok, diff} = Diff.compute(base, curr)

      assert [%CategoryDelta{delta: 6, status: :regressed}] = diff.imprecision
      assert diff.net_total == 6
      assert length(diff.regressions) == 1
      assert diff.improvements == []
    end

    test "unchanged categories show delta 0 and aren't in improvements/regressions" do
      base = snapshot(%{"cat" => category(5)})
      curr = snapshot(%{"cat" => category(5)})

      assert {:ok, diff} = Diff.compute(base, curr)

      assert [%CategoryDelta{delta: 0, status: :unchanged}] = diff.imprecision
      assert diff.improvements == []
      assert diff.regressions == []
    end

    test "categories new in current snapshot are flagged" do
      base = snapshot(%{})
      curr = snapshot(%{"new_cat" => category(3)})

      assert {:ok, diff} = Diff.compute(base, curr)

      assert diff.new_categories == ["new_cat"]
      assert diff.removed_categories == []

      [delta] = diff.imprecision
      assert delta.status == :new
      assert delta.baseline == 0
      assert delta.current == 3
    end

    test "categories removed in current snapshot are flagged" do
      base = snapshot(%{"gone_cat" => category(3)})
      curr = snapshot(%{})

      assert {:ok, diff} = Diff.compute(base, curr)

      assert diff.removed_categories == ["gone_cat"]
      assert diff.new_categories == []

      [delta] = diff.imprecision
      assert delta.status == :removed
      assert delta.baseline == 3
      assert delta.current == 0
    end

    test "net_total sums all imprecision deltas including trades" do
      # category A improves by 10, category B regresses by 3. Net: -7.
      base = snapshot(%{"a" => category(20), "b" => category(5)})
      curr = snapshot(%{"a" => category(10), "b" => category(8)})

      assert {:ok, diff} = Diff.compute(base, curr)

      assert diff.net_total == -7
      assert length(diff.improvements) == 1
      assert length(diff.regressions) == 1
    end

    test "by_project deltas are computed per project, dropping zero deltas" do
      base =
        snapshot(%{
          "cat" => category(10, by_project: %{"p1" => 6, "p2" => 4})
        })

      curr =
        snapshot(%{
          "cat" => category(7, by_project: %{"p1" => 3, "p2" => 4})
        })

      assert {:ok, diff} = Diff.compute(base, curr)

      [delta] = diff.imprecision
      # p1 dropped by 3, p2 unchanged.
      assert delta.by_project == %{"p1" => -3}
    end

    test "refuses to diff across schema versions" do
      base = snapshot(%{}, %{}, schema_version: 1)
      curr = snapshot(%{}, %{}, schema_version: 2)

      assert {:error, :schema_mismatch} = Diff.compute(base, curr)
    end
  end

  describe "compute/2 — shape gaps" do
    test "shape gap improvement surfaces removed rows" do
      base =
        snapshot(%{}, %{
          "coverage_ets_unused" => gap(2, [["Plug.Keys"], ["Plug.Sessions"]])
        })

      curr =
        snapshot(%{}, %{
          "coverage_ets_unused" => gap(1, [["Plug.Sessions"]])
        })

      assert {:ok, diff} = Diff.compute(base, curr)

      [gap_delta] = diff.shape_gaps
      assert %GapDelta{relation: "coverage_ets_unused", delta: -1} = gap_delta
      assert gap_delta.removed_rows == [["Plug.Keys"]]
      assert gap_delta.added_rows == []
    end

    test "shape gap regression surfaces added rows" do
      base = snapshot(%{}, %{"coverage_ets_unused" => gap(0, [])})

      curr =
        snapshot(%{}, %{
          "coverage_ets_unused" => gap(2, [["NewTable"], ["OtherTable"]])
        })

      assert {:ok, diff} = Diff.compute(base, curr)

      [gap_delta] = diff.shape_gaps
      assert gap_delta.delta == 2
      assert Enum.sort(gap_delta.added_rows) == [["NewTable"], ["OtherTable"]]
      assert gap_delta.removed_rows == []
    end

    test "shape gaps contribute to improvements/regressions but not net_total" do
      base =
        snapshot(
          %{"cat" => category(10)},
          %{"coverage_genserver_isolated" => gap(3, [["A"], ["B"], ["C"]])}
        )

      curr =
        snapshot(
          %{"cat" => category(5)},
          %{"coverage_genserver_isolated" => gap(1, [["A"]])}
        )

      assert {:ok, diff} = Diff.compute(base, curr)

      # net_total is imprecision-only: -5.
      assert diff.net_total == -5

      # Both the imprecision delta AND the gap delta appear in improvements.
      assert length(diff.improvements) == 2
    end
  end

  describe "improvements and regressions ordering" do
    test "sorted by magnitude descending" do
      base =
        snapshot(%{
          "small" => category(3),
          "medium" => category(10),
          "huge" => category(50)
        })

      curr =
        snapshot(%{
          "small" => category(1),
          "medium" => category(2),
          "huge" => category(10)
        })

      assert {:ok, diff} = Diff.compute(base, curr)

      magnitudes = Enum.map(diff.improvements, &abs(&1.delta))
      assert magnitudes == [40, 8, 2]
    end
  end
end
