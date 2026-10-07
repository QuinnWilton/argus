defmodule Argus.FindingsNoEngineTest do
  # Sync on purpose: ARGUS_CARGO is VM-wide, so this must not overlap with
  # the tests that build or run engines concurrently.
  use ExUnit.Case, async: false

  test "a machine without Rust is an explicit error, not a crash" do
    original = System.get_env("ARGUS_CARGO")

    on_exit(fn ->
      if original,
        do: System.put_env("ARGUS_CARGO", original),
        else: System.delete_env("ARGUS_CARGO")
    end)

    System.put_env("ARGUS_CARGO", "/nonexistent/cargo")
    refute Argus.FlowLog.available?()
    assert Argus.FlowLog.not_found_message() =~ "ARGUS_CARGO names /nonexistent/cargo"
    assert Argus.FlowLog.not_found_message() =~ "https://rustup.rs"

    assert {:error, {:flowlog_unavailable, {:rust_missing, _}}} = Argus.run_analyses([:lists])
  end
end
