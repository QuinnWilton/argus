defmodule Argus.Autoresearch.MeasureTest do
  use ExUnit.Case, async: false

  alias Argus.Autoresearch.Measure

  @moduletag :tmp_dir

  describe "discover_ebin_dirs/0" do
    test "finds argus and its dependencies under _build" do
      dirs = Measure.discover_ebin_dirs()

      # Must include argus itself.
      assert Enum.any?(dirs, &String.contains?(&1, "/argus/ebin"))

      # Must include beam_spy, which argus depends on.
      assert Enum.any?(dirs, &String.contains?(&1, "/beam_spy/ebin"))

      # All results should be under _build.
      assert Enum.all?(dirs, &String.contains?(&1, "_build"))
    end

    test "returns a sorted, deduplicated list" do
      dirs = Measure.discover_ebin_dirs()
      assert dirs == Enum.sort(dirs)
      assert dirs == Enum.uniq(dirs)
    end
  end

  describe "run_corpus/2" do
    test "returns {:missing, name} for projects with nil paths", %{tmp_dir: tmp_dir} do
      results =
        Measure.run_corpus(
          [{"not_installed", nil}],
          output_dir: tmp_dir
        )

      assert [{"not_installed", {:missing, "not_installed"}}] = results
    end

    @tag :slow
    @tag :requires_corpus
    test "runs coverage against a real project and returns a decoded report",
         %{tmp_dir: tmp_dir} do
      plug_path = "/Users/quinn/dev/beam_box/sample_projects/plug"

      if not File.dir?(plug_path) do
        # Skip when the corpus isn't available — we don't want the
        # test suite to depend on a specific user's machine layout.
        IO.puts(:stderr, "Skipping Measure integration test: plug not at #{plug_path}")
        :ok
      else
        results =
          Measure.run_corpus(
            [{"plug", plug_path}],
            output_dir: tmp_dir,
            concurrency: 1,
            timeout_s: 120
          )

        assert [{"plug", {:ok, report}}] = results
        assert is_map(report)
        assert %{"analyses" => %{"coverage" => %{"status" => "ok"}}} = report
      end
    end

    test "order of results matches order of input projects", %{tmp_dir: tmp_dir} do
      # Use three nil-path projects so we don't incur subprocess costs.
      projects = [{"zebra", nil}, {"alpha", nil}, {"mike", nil}]

      results = Measure.run_corpus(projects, output_dir: tmp_dir)

      assert Enum.map(results, fn {name, _} -> name end) == ["zebra", "alpha", "mike"]
    end

    test "on_progress callback fires for each project", %{tmp_dir: tmp_dir} do
      pid = self()

      projects = [{"a", nil}, {"b", nil}]

      Measure.run_corpus(projects,
        output_dir: tmp_dir,
        on_progress: fn name, result -> send(pid, {:progress, name, result}) end
      )

      assert_received {:progress, "a", {:missing, "a"}}
      assert_received {:progress, "b", {:missing, "b"}}
    end
  end
end
