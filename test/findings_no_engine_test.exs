defmodule Argus.FindingsNoEngineTest do
  # Sync on purpose: ARGUS_CARGO is VM-wide, so this must not overlap with
  # the tests that build or run engines concurrently.
  use ExUnit.Case, async: false

  test "a machine without Rust is an explicit error, not a crash" do
    env = ~w(ARGUS_CARGO ARGUS_FLOWLOG_PREBUILT)
    original = Map.new(env, &{&1, System.get_env(&1)})

    on_exit(fn ->
      for {name, value} <- original do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)

    System.put_env("ARGUS_CARGO", "/nonexistent/cargo")
    # No release's bundle either, which would otherwise stand in for Rust.
    System.put_env("ARGUS_FLOWLOG_PREBUILT", "0")
    refute Argus.FlowLog.available?()
    assert Argus.FlowLog.not_found_message() =~ "ARGUS_CARGO names /nonexistent/cargo"
    assert Argus.FlowLog.not_found_message() =~ "https://rustup.rs"
    assert Argus.FlowLog.not_found_message() =~ "ARGUS_FLOWLOG_PREBUILT=0"

    assert {:error, {:flowlog_unavailable, {:no_engines, {:rust_missing, _}, :disabled}}} =
             Argus.run_analyses([:lists])
  end
end
