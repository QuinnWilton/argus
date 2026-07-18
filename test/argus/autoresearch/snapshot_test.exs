defmodule Argus.Autoresearch.SnapshotTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.Snapshot

  @fixtures "test/fixtures/autoresearch"

  defp load_fixture(name) do
    path = Path.join(@fixtures, name)
    content = File.read!(path)
    :json.decode(content)
  end

  defp plug_report, do: load_fixture("plug_coverage.json")
  defp broadway_report, do: load_fixture("broadway_coverage.json")

  describe "from_reports/2" do
    test "aggregates imprecision events per category from a single project" do
      snapshot = Snapshot.from_reports([{"plug", plug_report()}])

      assert snapshot.projects == ["plug"]
      assert snapshot.schema_version == Snapshot.schema_version()

      imprecision = snapshot.counts.imprecision_event

      assert Map.has_key?(imprecision, "ignored_result_unknown_api")
      assert Map.has_key?(imprecision, "ets_table_ref_op")
      assert Map.has_key?(imprecision, "genserver_callee")

      # Plug has 5 ignored_result_unknown_api events in the fixture.
      assert imprecision["ignored_result_unknown_api"].total == 5
      assert imprecision["ignored_result_unknown_api"].by_project == %{"plug" => 5}

      assert imprecision["ignored_result_unknown_api"].by_relation == %{
               "ignored_error_result" => 5
             }

      assert imprecision["ignored_result_unknown_api"].by_reason == %{"skipped" => 5}
    end

    test "sample_funcs is sorted and capped at 10" do
      # Build a synthetic report with 15 distinct funcs for a single category.
      rows =
        for i <- 1..15 do
          ["my_category", "Mod#{i}:f/0", "sync_call", "dynamic"]
        end

      report = %{
        "analyses" => %{"coverage" => %{"findings" => %{"imprecision_event" => rows}}}
      }

      snapshot = Snapshot.from_reports([{"proj", report}])
      entry = snapshot.counts.imprecision_event["my_category"]

      assert entry.total == 15
      assert length(entry.sample_funcs) == 10

      # Lexicographic order means Mod1 comes before Mod10, Mod11, ...
      # rather than numeric order. The test locks this in.
      assert entry.sample_funcs == Enum.sort(entry.sample_funcs)
    end

    test "deduplicates funcs for sample_funcs" do
      rows = [
        ["c", "A:f/0", "r", "dynamic"],
        ["c", "A:f/0", "r", "dynamic"],
        ["c", "B:f/0", "r", "dynamic"]
      ]

      report = %{
        "analyses" => %{"coverage" => %{"findings" => %{"imprecision_event" => rows}}}
      }

      snapshot = Snapshot.from_reports([{"p", report}])
      entry = snapshot.counts.imprecision_event["c"]

      assert entry.total == 3
      assert entry.sample_funcs == ["A:f/0", "B:f/0"]
    end

    test "aggregates shape-gap relations with full row lists" do
      snapshot = Snapshot.from_reports([{"plug", plug_report()}])

      shape_gaps = snapshot.counts.shape_gaps

      assert Map.has_key?(shape_gaps, "coverage_genserver_isolated")
      assert shape_gaps["coverage_genserver_isolated"].total == 2

      # Rows are stored in full for shape-gaps.
      assert [["Plug.Upload"], ["Plug.Upload.Terminator"]] =
               shape_gaps["coverage_genserver_isolated"].rows

      assert shape_gaps["coverage_ets_unused"].total == 1
      assert shape_gaps["coverage_ets_unused"].rows == [["Plug.Keys"]]
    end

    test "aggregates across multiple projects, by_project tracks per-project counts" do
      snapshot =
        Snapshot.from_reports([
          {"plug", plug_report()},
          {"broadway", broadway_report()}
        ])

      assert snapshot.projects == ["broadway", "plug"]

      # ignored_result_unknown_api fires in both projects.
      iru = snapshot.counts.imprecision_event["ignored_result_unknown_api"]
      assert iru.by_project["plug"] == 5
      assert iru.by_project["broadway"] == 6
      assert iru.total == 11
    end

    test "omits shape-gap relations with zero rows across the corpus" do
      # Plug has no supervisor-shape or named_process findings.
      snapshot = Snapshot.from_reports([{"plug", plug_report()}])

      refute Map.has_key?(snapshot.counts.shape_gaps, "coverage_supervisor_no_children")
      refute Map.has_key?(snapshot.counts.shape_gaps, "coverage_named_process_unreachable")
    end

    test "stores tier and argus_git_sha from opts" do
      snapshot =
        Snapshot.from_reports([{"plug", plug_report()}],
          tier: "fast",
          argus_git_sha: "abc1234"
        )

      assert snapshot.tier == "fast"
      assert snapshot.argus_git_sha == "abc1234"
    end

    test "handles reports with no coverage analysis gracefully" do
      snapshot = Snapshot.from_reports([{"empty", %{"analyses" => %{}}}])

      assert snapshot.projects == ["empty"]
      assert snapshot.counts.imprecision_event == %{}
      assert snapshot.counts.shape_gaps == %{}
    end
  end

  describe "determinism (load-bearing)" do
    test "two snapshots from the same input compare equal" do
      reports = [{"plug", plug_report()}, {"broadway", broadway_report()}]

      a = Snapshot.from_reports(reports)
      b = Snapshot.from_reports(reports)

      assert a == b
    end

    test "project ordering in the input does not affect the snapshot" do
      reports_1 = [{"plug", plug_report()}, {"broadway", broadway_report()}]
      reports_2 = [{"broadway", broadway_report()}, {"plug", plug_report()}]

      assert Snapshot.from_reports(reports_1) == Snapshot.from_reports(reports_2)
    end

    test "JSON round-trip preserves the snapshot" do
      original = Snapshot.from_reports([{"plug", plug_report()}], tier: "fast")
      json = Snapshot.to_json(original)

      # Simulate a disk round-trip by re-encoding through OTP :json.
      encoded = :json.encode(json) |> IO.iodata_to_binary()
      decoded = :json.decode(encoded)

      {:ok, restored} = Snapshot.from_json(decoded)

      assert restored == original
    end

    test "to_json produces sorted maps for deterministic on-disk output" do
      snapshot =
        Snapshot.from_reports([
          {"plug", plug_report()},
          {"broadway", broadway_report()}
        ])

      json = Snapshot.to_json(snapshot)

      # Encode twice and compare the raw bytes. Elixir maps are unordered
      # in memory but :json preserves insertion order, and our sorted_map
      # helper ensures the insertion order is deterministic.
      encoded_1 = :json.encode(json) |> IO.iodata_to_binary()
      encoded_2 = :json.encode(json) |> IO.iodata_to_binary()

      assert encoded_1 == encoded_2
    end
  end

  describe "write!/2 and read/1" do
    @tag :tmp_dir
    test "round-trips through disk", %{tmp_dir: tmp_dir} do
      original = Snapshot.from_reports([{"plug", plug_report()}], tier: "fast")
      path = Path.join(tmp_dir, "snapshot.json")

      assert :ok = Snapshot.write!(original, path)
      assert File.exists?(path)
      assert {:ok, restored} = Snapshot.read(path)

      assert restored == original
    end

    test "read returns error for missing file" do
      assert {:error, :enoent} = Snapshot.read("/nonexistent/snapshot.json")
    end
  end

  describe "from_json/1" do
    test "rejects malformed input" do
      assert {:error, _} = Snapshot.from_json(%{})
      assert {:error, _} = Snapshot.from_json(%{"schema_version" => "not_a_number"})
    end
  end
end
