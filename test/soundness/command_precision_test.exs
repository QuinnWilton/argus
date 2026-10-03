defmodule Argus.Soundness.CommandPrecisionTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.CodeExecution
  alias Argus.Test.Memo

  test "a literal command fragment cannot suppress a dynamic suffix, nested value or branch" do
    assert {:ok, results} = Memo.analyze([CodeExecution], :unsafe_input)

    functions =
      for [_, func, _, "code" | _] <- results["sink_without_request_path"],
          do: func

    for name <- [:os_cmd, :partial_os_cmd, :nested_os_cmd, :branch_os_cmd, :dynamic_shell] do
      assert Enum.any?(functions, &String.contains?(&1, ":#{name}/"))
    end

    for name <- [:literal_os_cmd, :literal_os_cmd_options, :literal_shell] do
      refute Enum.any?(functions, &String.contains?(&1, ":#{name}/"))
    end
  end
end
