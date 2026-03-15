defmodule Argus.LLMTest do
  use ExUnit.Case

  @mock_llm Path.expand("support/mock_llm.sh", __DIR__)

  describe "available?/1" do
    test "returns true when binary is explicitly provided" do
      assert Argus.LLM.available?(llm_bin: @mock_llm)
    end

    test "returns false when binary does not exist" do
      assert Argus.LLM.available?(llm_bin: "/nonexistent/bin") == false
    end
  end

  describe "resolve_bin/1" do
    test "prefers :llm_bin option" do
      assert Argus.LLM.resolve_bin(llm_bin: "/custom/bin") == "/custom/bin"
    end

    test "falls back to ARGUS_LLM_BIN env" do
      System.put_env("ARGUS_LLM_BIN", "/env/bin")

      try do
        assert Argus.LLM.resolve_bin([]) == "/env/bin"
      after
        System.delete_env("ARGUS_LLM_BIN")
      end
    end
  end

  describe "prompt/2" do
    @tag :llm
    test "returns response from mock LLM" do
      assert {:ok, response} = Argus.LLM.prompt("hello", llm_bin: @mock_llm)
      assert is_binary(response)
      assert response != ""
    end

    @tag :llm
    test "returns error for non-zero exit" do
      assert {:error, {:llm_error, 1, _output}} =
               Argus.LLM.prompt("FORCE_ERROR", llm_bin: @mock_llm)
    end

    test "returns :llm_not_found when binary does not exist" do
      assert {:error, :llm_not_found} =
               Argus.LLM.prompt("test", llm_bin: "/nonexistent/binary_xyz_123")
    end

    @tag :llm
    test "returns :llm_timeout on slow response" do
      assert {:error, :llm_timeout} =
               Argus.LLM.prompt("FORCE_TIMEOUT", llm_bin: @mock_llm, llm_timeout: 200)
    end
  end
end
