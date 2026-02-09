defmodule ArgusTest do
  use ExUnit.Case

  test "analyze/2 delegates to Analysis.run/3" do
    assert {:error, {:unknown_analysis, :nonexistent}} = Argus.analyze([:lists], :nonexistent)
  end

  test "analyze/2 returns error for non-existent module" do
    assert {:error, {:not_found, :fake_module_xyz}} = Argus.analyze([:fake_module_xyz], :cfg)
  end
end
