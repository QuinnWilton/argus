defmodule Argus.AnalysesTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis

  @expected_analyses [
    :callgraph,
    :cfg,
    :ets,
    :liveness,
    :message_flow,
    :one_for_one_coupling,
    :reachability,
    :reaching_def,
    :supervision,
    :tail_call
  ]

  describe "discovery" do
    test "finds all 10 built-in analysis modules" do
      modules = Analysis.builtin_analysis_modules()
      assert length(modules) == 10
    end

    test "builtin_analyses/0 returns all names sorted" do
      names = Analysis.builtin_analyses()
      assert names == @expected_analyses
    end
  end

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

    test "cfg has cfg_edge relation" do
      assert {:ok, relations} = Analysis.output_relations(:cfg)
      assert [%{name: :cfg_edge}] = relations
    end
  end

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

    test "names are unique across all modules" do
      names = Enum.map(Analysis.builtin_analysis_modules(), & &1.name())
      assert length(names) == length(Enum.uniq(names))
    end
  end
end
