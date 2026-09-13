defmodule Argus.ReportTest do
  use ExUnit.Case, async: true

  alias Argus.Report

  @moduletag :tmp_dir

  describe "build_project_report/2" do
    test "structures successful analysis results" do
      meta = %{
        "name" => "my_app",
        "path" => "/tmp/my_app",
        "build_system" => "mix",
        "module_count" => 10,
        "timestamp" => "2026-01-01T00:00:00Z",
        "duration_ms" => 1234
      }

      analysis_results = [
        {:unlinked_spawn,
         {:ok,
          %{
            "unlinked_spawn" => [["MyApp.Worker:start/0", "spawn"]],
            "call_edge" => [["a", "b"]]
          }}},
        {:ets,
         {:ok,
          %{
            "ets_no_heir" => [],
            "call_edge" => [["x", "y"]]
          }}}
      ]

      report = Report.build_project_report(meta, analysis_results)

      assert report["meta"] == meta
      assert report["summary"]["analyses_run"] == 2
      assert report["summary"]["analyses_failed"] == 0

      # unlinked_spawn: intermediate call_edge filtered out, 1 finding.
      us = report["analyses"]["unlinked_spawn"]
      assert us["status"] == "ok"
      assert us["finding_count"] == 1
      assert us["findings"]["unlinked_spawn"] == [["MyApp.Worker:start/0", "spawn"]]
      refute Map.has_key?(us["findings"], "call_edge")

      # ets: ets_no_heir had empty rows so it's excluded, 0 findings.
      ets = report["analyses"]["ets"]
      assert ets["status"] == "ok"
      assert ets["finding_count"] == 0
      assert ets["findings"] == %{}

      assert report["summary"]["total_findings"] == 1
    end

    test "records analysis errors" do
      meta = %{"name" => "broken_app"}

      analysis_results = [
        {:call_cycle, {:error, {:souffle_failed, "timeout"}}},
        {:ets, {:ok, %{}}}
      ]

      report = Report.build_project_report(meta, analysis_results)

      cc = report["analyses"]["call_cycle"]
      assert cc["status"] == "error"
      assert cc["finding_count"] == 0
      assert cc["error"] =~ "souffle_failed"

      assert report["summary"]["analyses_failed"] == 1
      assert report["summary"]["total_findings"] == 0
    end

    test "passes through all relations for unknown (custom) analyses" do
      meta = %{"name" => "custom_test"}

      analysis_results = [
        {:nonexistent_analysis,
         {:ok,
          %{
            "my_relation" => [["a", "b"]],
            "empty_one" => []
          }}}
      ]

      report = Report.build_project_report(meta, analysis_results)

      entry = report["analyses"]["nonexistent_analysis"]
      assert entry["status"] == "ok"
      # Empty relations are excluded, non-empty pass through.
      assert entry["findings"] == %{"my_relation" => [["a", "b"]]}
      assert entry["finding_count"] == 1
    end
  end

  describe "encode_json/1" do
    test "encodes maps to JSON strings" do
      json = Report.encode_json(%{"key" => "value"})
      assert is_binary(json)
      assert :json.decode(json) == %{"key" => "value"}
    end

    test "encodes nested structures" do
      data = %{"list" => [1, 2, 3], "nested" => %{"a" => true}}
      json = Report.encode_json(data)
      assert :json.decode(json) == data
    end
  end

  describe "write_json/2" do
    test "writes valid JSON to the given path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.json")
      data = %{"hello" => "world", "count" => 42}

      assert :ok = Report.write_json(data, path)
      assert File.exists?(path)
      refute File.exists?(path <> ".tmp")

      content = File.read!(path)
      assert :json.decode(content) == data
    end

    test "creates parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "deep", "test.json"])
      assert :ok = Report.write_json(%{"ok" => true}, path)
      assert File.exists?(path)
    end

    test "overwrites existing files", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "overwrite.json")
      Report.write_json(%{"v" => 1}, path)
      Report.write_json(%{"v" => 2}, path)

      assert :json.decode(File.read!(path)) == %{"v" => 2}
    end
  end

  describe "unresolved targets" do
  end
end
