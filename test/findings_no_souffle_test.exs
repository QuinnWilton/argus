defmodule Argus.FindingsNoSouffleTest do
  # Sync on purpose: masking PATH is VM-wide, so this must not overlap
  # with the souffle-backed tests running concurrently.
  use ExUnit.Case, async: false

  alias Argus.Souffle

  test "missing souffle is an explicit error, not a crash" do
    original_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", original_path) end)

    System.put_env("PATH", "/nonexistent_souffle_free_dir")
    refute Souffle.available?()

    assert {:error, :souffle_not_found} = Argus.run_analyses([:lists])
  end
end
