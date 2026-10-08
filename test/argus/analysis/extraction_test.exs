defmodule Argus.Analysis.ExtractionTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis
  alias Argus.Analysis.Extraction
  alias Argus.Test.Files

  @moduletag :tmp_dir

  @tag :flowlog
  test "an extraction is staged: stage 0 is in the directory it returns" do
    assert {:ok, facts_dir} = Analysis.extract_facts([:lists], [:startup])

    try do
      for relation <-
            ~w(call_edge call_site unconditional_call_edge call_tag fun_handed_to fun_built) do
        assert File.exists?(Path.join(facts_dir, "#{relation}.facts"))
      end
    after
      Files.rm_rf!(Path.dirname(facts_dir))
    end
  end

  describe "through a store" do
    @describetag :flowlog

    @describetag :cache

    test "the directory is read-only links into the store", %{tmp_dir: store} do
      modules = [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow, :gen_server]
      assert {:ok, dir} = Analysis.extract_facts(modules, [:startup, :races], store: store)

      try do
        linked = Path.join(dir, "call_arg.facts")
        assert File.stat!(linked).links > 1
        assert File.stat!(linked).access == :read
      after
        Files.rm_rf!(Path.dirname(dir))
      end
    end
  end

  describe "the points-to stage" do
    @tag :flowlog
    test "is derived when an analysis reads it, and only then" do
      assert {:ok, reads} = Analysis.extract_facts([:lists], [:startup])
      assert {:ok, reads_not} = Analysis.extract_facts([:lists], [:effects])

      assert {:ok, deferred} =
               Analysis.extract_facts([:lists], [:startup], points_to: :deferred)

      try do
        staged = &File.exists?(Path.join(&1, "#{&2}.facts"))

        for relation <- Extraction.points_to_relations() do
          assert staged.(reads, relation)
          refute staged.(reads_not, relation)
          refute staged.(deferred, relation)
        end
      after
        for dir <- [reads, reads_not, deferred], do: Files.rm_rf!(Path.dirname(dir))
      end
    end

    @tag :flowlog
    test "is read by the analyses that ask about processes" do
      assert Extraction.reads_points_to?(:startup)
      assert Extraction.reads_points_to?(:races)
      refute Extraction.reads_points_to?(:effects)
      refute Extraction.reads_points_to?(:structure)
    end

    test "stage0: :provided trusts the caller for it too", %{tmp_dir: dir} do
      assert :ok = Extraction.ensure_points_to(dir, [:startup], stage0: :provided)
      assert File.ls!(dir) == []
    end

    @tag :flowlog
    test "is not derived for analyses that do not read it", %{tmp_dir: dir} do
      assert :ok = Extraction.ensure_points_to(dir, [:effects, :structure], [])
      assert File.ls!(dir) == []
    end

    test "a staged directory is left as it is", %{tmp_dir: dir} do
      for relation <- Extraction.points_to_relations() do
        File.write!(Path.join(dir, "#{relation}.facts"), "")
      end

      assert :ok = Extraction.ensure_points_to(dir, [:startup], [])
      assert length(File.ls!(dir)) == length(Extraction.points_to_relations())
    end

    test "the program ships in priv/dl" do
      assert File.exists?(Extraction.points_to_rules_path())
      assert Extraction.points_to_rules_path() == Argus.Analysis.points_to_rules_path()
      assert Extraction.points_to_relations() == Argus.Analysis.points_to_relations()
    end
  end

  describe "ensure_stage0/2" do
    test "stage0: :provided trusts the caller, even with nothing there", %{tmp_dir: dir} do
      assert :ok = Extraction.ensure_stage0(dir, stage0: :provided)
      assert File.ls!(dir) == []
    end

    test "a staged directory is left as it is", %{tmp_dir: dir} do
      for relation <-
            ~w(call_edge call_site unconditional_call_edge call_tag fun_handed_to fun_built) do
        File.write!(Path.join(dir, "#{relation}.facts"), "")
      end

      assert :ok = Extraction.ensure_stage0(dir, [])
      assert length(File.ls!(dir)) == 6
    end
  end

  test "the stage-0 program ships in priv/dl" do
    assert File.exists?(Extraction.stage0_rules_path())
    assert Extraction.stage0_rules_path() == Argus.Analysis.stage0_rules_path()
  end
end
