defmodule ArgusTest do
  use ExUnit.Case

  test "module exists" do
    assert is_list(Argus.module_info(:attributes))
  end
end
