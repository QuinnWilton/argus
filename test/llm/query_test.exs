defmodule Argus.LLM.QueryTest do
  use ExUnit.Case

  alias Argus.LLM.Query
  alias Argus.Souffle.CLI

  @mock_llm Path.expand("../support/mock_llm.sh", __DIR__)

  describe "build_synthesis_prompt/1" do
    test "includes available input relations from schema" do
      prompt = Query.build_synthesis_prompt("find exported functions")
      assert prompt =~ "function_def"
      assert prompt =~ "instruction"
      assert prompt =~ "remote_call"
    end

    test "includes .input declarations" do
      prompt = Query.build_synthesis_prompt("find exported functions")
      assert prompt =~ ".input function_def"
    end

    test "includes the user question" do
      prompt = Query.build_synthesis_prompt("which modules call GenServer.call?")
      assert prompt =~ "which modules call GenServer.call?"
    end

    test "includes example query" do
      prompt = Query.build_synthesis_prompt("test question")
      # The example should contain call_cycle.dl content.
      assert prompt =~ "call_cycle" or prompt =~ "example not available"
    end

    test "includes standard includes guidance" do
      prompt = Query.build_synthesis_prompt("test question")
      assert prompt =~ "imports.dl"
    end
  end

  describe "validate/1" do
    test "accepts valid Datalog with output declaration" do
      dl = """
      .include "../clientlib/imports.dl"
      .decl result(func: symbol)
      .output result
      .input function_def
      result(func) :- function_def(func, _, _, _, _, 1).
      """

      assert :ok = Query.validate(dl)
    end

    test "rejects Datalog without output declaration" do
      dl = """
      .decl result(func: symbol)
      .input function_def
      result(func) :- function_def(func, _, _, _, _, 1).
      """

      assert {:error, :no_output_declaration} = Query.validate(dl)
    end

    test "rejects Datalog with unknown input relations" do
      dl = """
      .decl result(func: symbol)
      .output result
      .input function_def
      .input nonexistent_relation
      result(func) :- function_def(func, _, _, _, _, 1).
      """

      assert {:error, {:unknown_relations, ["nonexistent_relation"]}} = Query.validate(dl)
    end

    test "accepts clientlib-derived relations" do
      dl = """
      .decl result(from: symbol, to: symbol)
      .output result
      .input call_edge
      result(from, to) :- call_edge(from, to).
      """

      # call_edge is derived by clientlib, not a Schema relation, but should be allowed.
      assert :ok = Query.validate(dl)
    end
  end

  describe "synthesize/2" do
    @tag :llm
    test "returns Datalog from mock LLM" do
      assert {:ok, dl} = Query.synthesize("find exported functions", llm_bin: @mock_llm)
      assert dl =~ ".output"
      assert dl =~ "function_def"
    end
  end

  describe "run/3" do
    @tag :llm
    test "end-to-end with mock LLM" do
      skip_without_souffle()

      assert {:ok, results} =
               Query.run("find exported functions", [:lists],
                 llm_bin: @mock_llm,
                 souffle_timeout: 30_000
               )

      assert is_map(results)
      assert Map.has_key?(results, "query_result")
      assert length(results["query_result"]) > 0
    end
  end

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end
end
