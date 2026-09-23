defmodule Argus.Extractor.DispatchLiteralTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.Dispatch

  describe "branch_targets/1" do
    test "a literal's value branches nowhere" do
      assert Dispatch.branch_targets({:move, {:literal, {:f, 3}}, {:x, 0}}) == []
    end

    test "labels in an improper operand list are found" do
      assert Enum.sort(Dispatch.branch_targets({:odd, [{:f, 3} | {:f, 4}]})) == [3, 4]
    end
  end
end
