defmodule Argus.ExtractTest do
  use ExUnit.Case, async: true

  alias Argus.Extract

  @moduletag :tmp_dir

  describe "extract/2" do
    test "extracts facts from a single module" do
      assert {:ok, facts} = Extract.extract([:lists])
      assert map_size(facts) > 0
      assert length(facts[:instruction]) > 0
      assert length(facts[:function_def]) > 0
    end

    test "extracts facts from multiple modules" do
      assert {:ok, facts} = Extract.extract([:lists, :maps])
      mod_infos = facts[:module_info]
      mods = Enum.map(mod_infos, fn [mod, _] -> mod end)
      assert ":lists" in mods
      assert ":maps" in mods
    end

    test "extracts facts from Elixir modules" do
      assert {:ok, facts} = Extract.extract([Enum])
      assert length(facts[:instruction]) > 0
    end

    test "returns error for non-existent module" do
      assert {:error, {:not_found, :definitely_not_a_real_module}} =
               Extract.extract([:definitely_not_a_real_module])
    end

    test "accepts beam file paths" do
      path = to_string(:code.which(:lists))
      assert {:ok, facts} = Extract.extract([path])
      assert length(facts[:instruction]) > 0
    end
  end

  describe "run/3" do
    test "writes .facts files to output directory", %{tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Extract.run([:lists], tmp_dir)

      # Check that fact files were created.
      assert File.exists?(Path.join(tmp_dir, "instruction.facts"))
      assert File.exists?(Path.join(tmp_dir, "function_def.facts"))
      assert File.exists?(Path.join(tmp_dir, "module_info.facts"))
    end

    test "fact files are well-formed TSV", %{tmp_dir: tmp_dir} do
      {:ok, _} = Extract.run([:lists], tmp_dir)

      {:ok, rows} = Extract.read_facts(Path.join(tmp_dir, "function_def.facts"))
      assert length(rows) > 0

      # function_def has 6 fields per the schema.
      for row <- rows do
        assert length(row) == 6, "expected 6 fields, got #{length(row)}: #{inspect(row)}"
      end
    end

    test "fact files contain expected content", %{tmp_dir: tmp_dir} do
      {:ok, _} = Extract.run([:lists], tmp_dir)

      {:ok, rows} = Extract.read_facts(Path.join(tmp_dir, "module_info.facts"))
      assert Enum.any?(rows, fn [mod, _] -> mod == ":lists" end)
    end

    test "handles multiple modules", %{tmp_dir: tmp_dir} do
      {:ok, _} = Extract.run([:lists, :maps], tmp_dir)

      {:ok, rows} = Extract.read_facts(Path.join(tmp_dir, "module_info.facts"))
      mods = Enum.map(rows, fn [mod, _] -> mod end)
      assert ":lists" in mods
      assert ":maps" in mods
    end
  end

  describe "extract/2 edge cases" do
    test "empty module list returns empty facts" do
      assert {:ok, facts} = Extract.extract([])
      assert facts == %{}
    end
  end

  describe "run/3 edge cases" do
    test "empty module list returns ok with output dir", %{tmp_dir: tmp_dir} do
      assert {:ok, ^tmp_dir} = Extract.run([], tmp_dir)
    end
  end

  describe "read_facts/1" do
    test "reads TSV correctly", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.facts")
      File.write!(path, "a\tb\tc\nd\te\tf\n")

      assert {:ok, [["a", "b", "c"], ["d", "e", "f"]]} = Extract.read_facts(path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Extract.read_facts("/nonexistent/path.facts")
    end
  end
end
