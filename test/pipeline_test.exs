defmodule Argus.PipelineTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline

  @moduletag :tmp_dir

  describe "extract/2" do
    test "extracts facts from a single module" do
      assert {:ok, facts} = Pipeline.extract([:lists])
      assert map_size(facts) > 0
      assert length(facts[:instruction]) > 0
      assert length(facts[:function_def]) > 0
    end

    test "extracts facts from multiple modules" do
      assert {:ok, facts} = Pipeline.extract([:lists, :maps])
      mod_infos = facts[:module_info]
      mods = Enum.map(mod_infos, fn [mod, _] -> mod end)
      assert ":lists" in mods
      assert ":maps" in mods
    end

    test "extracts facts from Elixir modules" do
      assert {:ok, facts} = Pipeline.extract([Enum])
      assert length(facts[:instruction]) > 0
    end

    test "returns error for non-existent module" do
      assert {:error, {:not_found, :definitely_not_a_real_module}} =
               Pipeline.extract([:definitely_not_a_real_module])
    end

    test "accepts beam file paths" do
      path = to_string(:code.which(:lists))
      assert {:ok, facts} = Pipeline.extract([path])
      assert length(facts[:instruction]) > 0
    end
  end

  describe "run/3" do
    test "writes .facts files to output directory", %{tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Pipeline.run([:lists], tmp_dir)

      # Check that fact files were created.
      assert File.exists?(Path.join(tmp_dir, "instruction.facts"))
      assert File.exists?(Path.join(tmp_dir, "function_def.facts"))
      assert File.exists?(Path.join(tmp_dir, "module_info.facts"))
    end

    test "fact files are well-formed TSV", %{tmp_dir: tmp_dir} do
      {:ok, _} = Pipeline.run([:lists], tmp_dir)

      {:ok, rows} = Pipeline.read_facts(Path.join(tmp_dir, "function_def.facts"))
      assert length(rows) > 0

      # function_def has 6 fields per the schema.
      for row <- rows do
        assert length(row) == 6, "expected 6 fields, got #{length(row)}: #{inspect(row)}"
      end
    end

    test "fact files contain expected content", %{tmp_dir: tmp_dir} do
      {:ok, _} = Pipeline.run([:lists], tmp_dir)

      {:ok, rows} = Pipeline.read_facts(Path.join(tmp_dir, "module_info.facts"))
      assert Enum.any?(rows, fn [mod, _] -> mod == ":lists" end)
    end

    test "handles multiple modules", %{tmp_dir: tmp_dir} do
      {:ok, _} = Pipeline.run([:lists, :maps], tmp_dir)

      {:ok, rows} = Pipeline.read_facts(Path.join(tmp_dir, "module_info.facts"))
      mods = Enum.map(rows, fn [mod, _] -> mod end)
      assert ":lists" in mods
      assert ":maps" in mods
    end
  end

  describe "extract/2 edge cases" do
    test "empty module list returns empty facts" do
      assert {:ok, facts} = Pipeline.extract([])
      assert facts == %{}
    end
  end

  describe "run/3 edge cases" do
    test "empty module list returns ok with output dir", %{tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Pipeline.run([], tmp_dir)
    end
  end

  describe "extract/2 imprecision tracing" do
    # MyGenServer.get_value/1 calls GenServer.call(server, :get) where
    # `server` is a parameter — resolve_callee returns "dynamic", which
    # the OTP extractor tracks as :genserver_callee imprecision. Gives us
    # a deterministic single-module test that exercises the gating.
    @imprecision_module Argus.Test.Fixtures.MyGenServer

    test "default run produces no imprecision facts" do
      {:ok, facts} =
        Pipeline.extract([@imprecision_module], extractors: [Argus.Extractors.OTP])

      assert facts[:imprecision] in [nil, []]
    end

    test "explicit trace_imprecision: false produces no imprecision facts" do
      {:ok, facts} =
        Pipeline.extract([@imprecision_module],
          extractors: [Argus.Extractors.OTP],
          trace_imprecision: false
        )

      assert facts[:imprecision] in [nil, []]
    end

    test "trace_imprecision: true records dynamic fallbacks" do
      {:ok, facts} =
        Pipeline.extract([@imprecision_module],
          extractors: [Argus.Extractors.OTP],
          trace_imprecision: true
        )

      imprecision = facts[:imprecision] || []
      assert length(imprecision) > 0

      assert Enum.any?(imprecision, fn [category, _func, relation, reason] ->
               category == "genserver_callee" and relation == "sync_call" and
                 reason == "dynamic"
             end)
    end

    test "tracing flag is cleared in the worker after extraction", %{tmp_dir: _} do
      # Run with tracing then without — the second run should see a clean
      # worker process (the first run's try/after must have cleared the flag).
      {:ok, _} =
        Pipeline.extract([@imprecision_module],
          extractors: [Argus.Extractors.OTP],
          trace_imprecision: true
        )

      {:ok, facts} =
        Pipeline.extract([@imprecision_module], extractors: [Argus.Extractors.OTP])

      assert facts[:imprecision] in [nil, []]
    end
  end

  describe "read_facts/1" do
    test "reads TSV correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.facts")
      File.write!(path, "a\tb\tc\nd\te\tf\n")

      assert {:ok, [["a", "b", "c"], ["d", "e", "f"]]} = Pipeline.read_facts(path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Pipeline.read_facts("/nonexistent/path.facts")
    end
  end
end
