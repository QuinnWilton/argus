defmodule Argus.Analysis.ExtractionTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis.Extraction

  @moduletag :tmp_dir

  test "an extraction is staged: stage 0 is in the directory it returns" do
    assert {:ok, facts_dir} = Extraction.extract_facts([:lists], [:startup])

    try do
      for relation <- ~w(call_edge call_site unconditional_call_edge call_tag fun_handed_to) do
        assert File.exists?(Path.join(facts_dir, "#{relation}.facts"))
      end
    after
      File.rm_rf!(Path.dirname(facts_dir))
    end
  end

  describe "through a store" do
    @describetag :cache

    defp contents(dir) do
      for name <- dir |> File.ls!() |> Enum.sort(), into: %{} do
        {name, File.read!(Path.join(dir, name))}
      end
    end

    test "the directory is the one extracted afresh, staged, and read-only links",
         %{tmp_dir: store} do
      modules = [Argus.Test.Fixtures.EtsBounded, Argus.Test.Fixtures.MissingRow, :gen_server]

      assert {:ok, afresh} = Extraction.extract_facts(modules, [:startup, :races])
      assert {:ok, cold} = Extraction.extract_facts(modules, [:startup, :races], cache: store)
      assert {:ok, warm} = Extraction.extract_facts(modules, [:startup, :races], cache: store)

      try do
        assert contents(cold) == contents(afresh)
        assert contents(warm) == contents(afresh)

        linked = Path.join(warm, "call_arg.facts")
        assert File.stat!(linked).links > 1
        assert File.stat!(linked).access == :read
      after
        for dir <- [afresh, cold, warm], do: File.rm_rf!(Path.dirname(dir))
      end

      # Removing a directory as a caller does leaves the store whole.
      assert store |> Path.join("work") |> File.ls!() == []
    end
  end

  describe "through a store, an extractor compiled in memory" do
    @describetag :cache

    test "is extracted afresh: no key can name its code", %{tmp_dir: store} do
      [{extractor, _beam}] =
        Code.compile_string("""
        defmodule Argus.Analysis.ExtractionTest.InMemory do
          def relations, do: [:http_route]
          def extract(_data), do: %{http_route: [["M", "GET", "/", "M", "f", "0"]]}
        end
        """)

      opts = [extractors: [extractor], cache: store]
      assert {:ok, dir} = Extraction.extract_facts([:lists], [:structure], opts)

      try do
        assert File.read!(Path.join(dir, "http_route.facts")) =~ "GET"
        refute File.exists?(Path.join(store, "shards"))
      after
        File.rm_rf!(Path.dirname(dir))
      end
    end
  end

  describe "the points-to stage" do
    test "is derived when an analysis reads it, and only then" do
      assert {:ok, reads} = Extraction.extract_facts([:lists], [:startup])
      assert {:ok, reads_not} = Extraction.extract_facts([:lists], [:effects])

      assert {:ok, deferred} =
               Extraction.extract_facts([:lists], [:startup], points_to: :deferred)

      try do
        staged = &File.exists?(Path.join(&1, "#{&2}.facts"))

        for relation <- Extraction.points_to_relations() do
          assert staged.(reads, relation)
          refute staged.(reads_not, relation)
          refute staged.(deferred, relation)
        end
      after
        for dir <- [reads, reads_not, deferred], do: File.rm_rf!(Path.dirname(dir))
      end
    end

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
      for relation <- ~w(call_edge call_site unconditional_call_edge call_tag fun_handed_to) do
        File.write!(Path.join(dir, "#{relation}.facts"), "")
      end

      assert :ok = Extraction.ensure_stage0(dir, [])
      assert length(File.ls!(dir)) == 5
    end
  end

  test "the stage-0 program ships in priv/dl" do
    assert File.exists?(Extraction.stage0_rules_path())
    assert Extraction.stage0_rules_path() == Argus.Analysis.stage0_rules_path()
  end
end
