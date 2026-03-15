defmodule Argus.LLM.ExplainTest do
  use ExUnit.Case

  alias Argus.LLM.Explain

  @mock_llm Path.expand("../support/mock_llm.sh", __DIR__)

  describe "build_prompt/3" do
    test "includes analysis name and description" do
      results = %{"call_cycle" => [["ModA", "ModB"]]}

      assert {:ok, prompt} = Explain.build_prompt(results, :call_cycle, [ModA, ModB])
      assert prompt =~ "Analysis: call_cycle"
      assert prompt =~ "deadlock"
    end

    test "labels findings with field names" do
      results = %{"call_cycle" => [["ModA", "ModB"]]}

      assert {:ok, prompt} = Explain.build_prompt(results, :call_cycle, [ModA, ModB])
      assert prompt =~ "mod_a=ModA"
      assert prompt =~ "mod_b=ModB"
    end

    test "includes module list" do
      results = %{"call_cycle" => [["ModA", "ModB"]]}

      assert {:ok, prompt} = Explain.build_prompt(results, :call_cycle, [ModA, ModB])
      assert prompt =~ "ModA"
      assert prompt =~ "ModB"
    end

    test "caps findings at 50 rows" do
      rows = for i <- 1..60, do: ["Mod#{i}", "Mod#{i + 1}"]
      results = %{"call_cycle" => rows}

      assert {:ok, prompt} = Explain.build_prompt(results, :call_cycle, [])
      assert prompt =~ "10 more rows"
    end

    test "returns :no_findings when all results are empty" do
      results = %{"call_cycle" => [], "_argus_mode" => [["precise"]]}

      assert {:error, :no_findings} = Explain.build_prompt(results, :call_cycle, [])
    end

    test "skips metadata keys starting with underscore" do
      results = %{
        "call_cycle" => [["ModA", "ModB"]],
        "_argus_mode" => [["precise"]]
      }

      assert {:ok, prompt} = Explain.build_prompt(results, :call_cycle, [ModA])
      refute prompt =~ "_argus_mode"
    end

    test "handles custom analysis" do
      results = %{"my_result" => [["val1", "val2"]]}

      assert {:ok, prompt} = Explain.build_prompt(results, {:custom, "/tmp/rules.dl"}, [])
      assert prompt =~ "Analysis: custom"
      # No field labels for custom analysis (no output_relations defined).
      assert prompt =~ "val1, val2"
    end
  end

  describe "explain/4" do
    @tag :llm
    test "returns explanation from mock LLM" do
      results = %{"call_cycle" => [["ModA", "ModB"]]}

      assert {:ok, text} =
               Explain.explain(results, :call_cycle, [ModA, ModB], llm_bin: @mock_llm)

      assert text =~ "Finding"
    end

    @tag :llm
    test "returns error when LLM fails" do
      results = %{"call_cycle" => [["FORCE_ERROR", "ModB"]]}

      assert {:error, {:llm_error, _, _}} =
               Explain.explain(results, :call_cycle, [], llm_bin: @mock_llm)
    end
  end
end
