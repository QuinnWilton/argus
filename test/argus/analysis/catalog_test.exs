defmodule Argus.Analysis.CatalogTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis
  alias Argus.Analysis.Catalog

  test "the names are the modules' names, in the same order" do
    assert Catalog.names() == Enum.map(Catalog.modules(), & &1.name())
    assert Catalog.names() == Enum.sort(Catalog.names())
  end

  test "Argus.Analysis's lookups are the catalog's" do
    assert Analysis.builtin_analyses() == Catalog.names()
    assert Analysis.builtin_analysis_modules() == Catalog.modules()
    assert Analysis.fetch_module(:startup) == Catalog.fetch(:startup)
    assert Analysis.output_relations(:mailbox) == Catalog.output_relations(:mailbox)
  end

  test "finding relations leave out the evidence relations" do
    {:ok, all} = Catalog.output_relations(:blocking)
    {:ok, findings} = Catalog.finding_relations(:blocking)

    assert Enum.any?(all, &Map.has_key?(&1, :evidence))
    assert findings == Enum.reject(all, &Map.has_key?(&1, :evidence))
  end

  describe "rules_path/1" do
    test "a built-in's program is its rules file under priv/dl" do
      {:ok, mod} = Catalog.fetch(:startup)
      assert {:ok, path} = Catalog.rules_path(:startup)
      assert path == Catalog.priv_dl(mod.rules_file())
      assert File.exists?(path)
    end

    test "an unknown name and a missing custom program are errors" do
      assert {:error, {:unknown_analysis, :nope}} = Catalog.rules_path(:nope)

      assert {:error, {:rules_not_found, "/nonexistent/rules.dl"}} =
               Catalog.rules_path({:custom, "/nonexistent/rules.dl"})
    end
  end
end
