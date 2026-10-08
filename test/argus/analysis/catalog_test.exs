defmodule Argus.Analysis.CatalogTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis
  alias Argus.Analysis.Catalog

  test "the names are the modules' names, in the same order" do
    assert Catalog.names() == Enum.map(Catalog.modules(), & &1.name())
    assert Catalog.names() == Enum.sort(Catalog.names())
    assert Catalog.names() == Enum.uniq(Catalog.names())
  end

  test "Argus.Analysis's lookups are the catalog's" do
    assert Analysis.builtin_analyses() == Catalog.names()
    assert Analysis.builtin_analysis_modules() == Catalog.modules()
    assert Analysis.fetch_module(:startup) == Catalog.fetch(:startup)
    assert Analysis.output_relations(:mailbox) == Catalog.output_relations(:mailbox)
  end

  test "finding relations leave out the evidence relations and the tooling re-tier" do
    {:ok, all} = Catalog.output_relations(:blocking)
    {:ok, findings} = Catalog.finding_relations(:blocking)

    assert Enum.any?(all, &Map.has_key?(&1, :evidence))
    assert Argus.Findings.Tooling.relation() in all

    assert findings ==
             Enum.reject(all, &(Map.has_key?(&1, :evidence) or Map.has_key?(&1, :retier)))
  end

  test "every built-in but coverage declares the tooling re-tier and runs its extractor" do
    for mod <- Catalog.modules(), mod.name() != :coverage do
      assert Argus.Findings.Tooling.relation() in mod.output_relations(), inspect(mod)
      assert Argus.Extractors.Tooling in mod.extractors(), inspect(mod)
    end
  end

  test "every built-in declares its outputs' fields with a type and a doc" do
    for mod <- Catalog.modules(), rel <- mod.output_relations() do
      assert is_atom(rel.name) and is_binary(rel.doc), inspect({mod, rel.name})

      for field <- rel.fields do
        assert match?(
                 {name, type, doc}
                 when is_atom(name) and type in [:symbol, :number] and
                        is_binary(doc),
                 field
               ),
               inspect({mod, rel.name, field})
      end
    end
  end

  test "Argus.analyze/2 says why a selection, a module or a program cannot run" do
    assert {:error, {:unknown_analysis, :nonexistent}} = Argus.analyze([:lists], :nonexistent)

    assert {:error, {:not_found, :fake_module_xyz}} =
             Argus.analyze([:fake_module_xyz], :startup)

    assert {:error, {:rules_not_found, "/nonexistent/rules.dl"}} =
             Argus.analyze([:lists], {:custom, "/nonexistent/rules.dl"})
  end

  describe "rules_path/1" do
    test "a built-in's program is its rules file under priv/dl" do
      {:ok, mod} = Catalog.fetch(:startup)
      assert {:ok, path} = Catalog.rules_path(:startup)
      assert path == Argus.Dl.path(mod.rules_file())
      assert File.exists?(path)
    end

    test "an unknown name and a missing custom program are errors" do
      assert {:error, {:unknown_analysis, :nope}} = Catalog.rules_path(:nope)

      assert {:error, {:rules_not_found, "/nonexistent/rules.dl"}} =
               Catalog.rules_path({:custom, "/nonexistent/rules.dl"})
    end
  end
end
