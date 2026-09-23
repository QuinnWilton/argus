defmodule Argus.Analysis.ExtractionTest do
  use ExUnit.Case, async: true

  alias Argus.Analysis.Extraction

  @moduletag :tmp_dir

  test "an extraction is staged: stage 0 is in the directory it returns" do
    assert {:ok, facts_dir} = Extraction.extract_facts([:lists], [:startup])

    try do
      for relation <- ~w(call_edge call_site unconditional_call_edge call_tag) do
        assert File.exists?(Path.join(facts_dir, "#{relation}.facts"))
      end
    after
      File.rm_rf!(Path.dirname(facts_dir))
    end
  end

  describe "ensure_stage0/2" do
    test "stage0: :provided trusts the caller, even with nothing there", %{tmp_dir: dir} do
      assert :ok = Extraction.ensure_stage0(dir, stage0: :provided)
      assert File.ls!(dir) == []
    end

    test "a staged directory is left as it is", %{tmp_dir: dir} do
      for relation <- ~w(call_edge call_site unconditional_call_edge call_tag) do
        File.write!(Path.join(dir, "#{relation}.facts"), "")
      end

      assert :ok = Extraction.ensure_stage0(dir, [])
      assert length(File.ls!(dir)) == 4
    end
  end

  test "the stage-0 program ships in priv/dl" do
    assert File.exists?(Extraction.stage0_rules_path())
    assert Extraction.stage0_rules_path() == Argus.Analysis.stage0_rules_path()
  end
end
