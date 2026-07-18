defmodule Argus.AnalysisTest do
  use ExUnit.Case

  alias Argus.Analysis
  alias Argus.Souffle

  @expected_analyses [
    :atom_safety,
    :call_cycle,
    :coverage,
    :deferred_startup_deadlock,
    :distributed,
    :error_handling,
    :ets,
    :gen_statem,
    :one_for_one_coupling,
    :process_bottleneck,
    :process_registry,
    :supervision,
    :sync_call_in_init,
    :timeout_chain,
    :unlinked_spawn,
    :unsafe_task
  ]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # -- Discovery ---------------------------------------------------------------

  describe "discovery" do
    test "finds all 16 built-in analysis modules" do
      modules = Analysis.builtin_analysis_modules()
      assert length(modules) == 16
    end

    test "builtin_analyses/0 returns all names sorted" do
      names = Analysis.builtin_analyses()
      assert names == @expected_analyses
    end

    test "names are unique across all modules" do
      names = Enum.map(Analysis.builtin_analysis_modules(), & &1.name())
      assert length(names) == length(Enum.uniq(names))
    end
  end

  # -- Lookup ------------------------------------------------------------------

  describe "fetch_module/1" do
    test "returns module for each built-in analysis" do
      for name <- @expected_analyses do
        assert {:ok, mod} = Analysis.fetch_module(name)
        assert mod.name() == name
      end
    end

    test "returns :error for unknown analysis" do
      assert :error = Analysis.fetch_module(:nonexistent)
    end
  end

  describe "output_relations/1" do
    test "returns relations for each built-in analysis" do
      for name <- @expected_analyses do
        assert {:ok, relations} = Analysis.output_relations(name)
        assert is_list(relations)
        assert length(relations) > 0
      end
    end

    test "returns :error for unknown analysis" do
      assert :error = Analysis.output_relations(:nonexistent)
    end

    test "supervision exposes its anti-pattern relations" do
      assert {:ok, relations} = Analysis.output_relations(:supervision)
      names = Enum.map(relations, & &1.name)
      assert :suspect_nonpermanent_dependency in names
      assert :wrong_start_order in names
    end
  end

  # -- Callback shape ----------------------------------------------------------

  describe "analysis module callbacks" do
    test "each module has a non-empty description" do
      for mod <- Analysis.builtin_analysis_modules() do
        desc = mod.description()
        assert is_binary(desc), "#{inspect(mod)}.description/0 must return a string"
        assert desc != "", "#{inspect(mod)}.description/0 must not be empty"
      end
    end

    test "each module references an existing rules file" do
      priv_dl = Path.join(:code.priv_dir(:argus), "dl")

      for mod <- Analysis.builtin_analysis_modules() do
        path = Path.join(priv_dl, mod.rules_file())
        assert File.exists?(path), "#{mod.rules_file()} not found for #{inspect(mod)}"
      end
    end

    test "each module's extractors are loaded modules" do
      for mod <- Analysis.builtin_analysis_modules() do
        for extractor <- mod.extractors() do
          assert Code.ensure_loaded?(extractor),
                 "extractor #{inspect(extractor)} from #{inspect(mod)} is not loadable"
        end
      end
    end

    test "output_relations have correct shape" do
      for mod <- Analysis.builtin_analysis_modules() do
        for rel <- mod.output_relations() do
          assert is_atom(rel.name), "#{inspect(mod)}: relation name must be an atom"
          assert is_list(rel.fields), "#{inspect(mod)}: fields must be a list"
          assert is_binary(rel.doc), "#{inspect(mod)}: doc must be a string"

          for {fname, ftype, fdoc} <- rel.fields do
            assert is_atom(fname), "#{inspect(mod)}: field name must be an atom"

            assert ftype in [:symbol, :number],
                   "#{inspect(mod)}: field type must be :symbol or :number"

            assert is_binary(fdoc), "#{inspect(mod)}: field doc must be a string"
          end
        end
      end
    end
  end

  # -- Custom analysis ---------------------------------------------------------

  describe "custom analysis" do
    test "custom analysis with user rules" do
      skip_without_souffle()

      tmp = System.tmp_dir!()
      rules_path = Path.join(tmp, "argus_custom_test.dl")

      File.write!(rules_path, """
      .include "#{Path.join(:code.priv_dir(:argus), "dl/base.dl")}"

      .decl exported_function(func: symbol)
      .output exported_function

      exported_function(func) :- function_def(func, _, _, _, _, 1).
      """)

      assert {:ok, results} = Argus.analyze([:lists], {:custom, rules_path})
      assert Map.has_key?(results, "exported_function")
      assert length(results["exported_function"]) > 0
    end

    test "custom analysis with non-existent rules file returns error" do
      assert {:error, {:rules_not_found, "/tmp/nonexistent_rules.dl"}} =
               Argus.analyze([:lists], {:custom, "/tmp/nonexistent_rules.dl"})
    end
  end

  # -- Errors ------------------------------------------------------------------

  describe "error handling" do
    test "returns error for unknown analysis" do
      assert {:error, {:unknown_analysis, :nonexistent}} =
               Argus.analyze([:lists], :nonexistent)
    end

    test "returns error for non-existent module" do
      assert {:error, {:not_found, :fake_module_xyz}} =
               Argus.analyze([:fake_module_xyz], :supervision)
    end
  end
end
