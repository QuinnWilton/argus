defmodule Argus.FlowLog.NativeTest do
  @moduledoc """
  The toolchain's Rust sources (`native/flowlog`) pass their own checks:
  the tool crate's unit tests (the tool includes the engine's host, so
  its tests are the host's too), `cargo fmt` and `cargo clippy`, the
  checks CI's native job runs.

  Each check runs once per version of the sources and Rust: a pass is
  stamped under the crate's `target/`, by `Argus.FlowLog.Native.digest/0`
  and `rustc`'s version, and a run whose stamp is there has nothing left
  to check. An edit under `native/flowlog` runs them again, in the run
  that rebuilds the toolchain.

  `rustfmt` and `clippy` are rustup components a Rust install may lack:
  without one, its check is skipped here and said so, and under `CI` it
  fails instead.
  """
  use ExUnit.Case, async: true

  alias Argus.FlowLog.Native
  alias Argus.FlowLog.Toolchain

  @moduletag :flowlog

  @crate Path.expand("../../../native/flowlog/tool", __DIR__)

  @rust Toolchain.rust()

  # Why a check cannot run on this machine, or false.
  unavailable = fn component ->
    case {@rust, component} do
      {{:error, reason}, _} ->
        "no Rust: " <> Toolchain.describe(reason)

      {{:ok, _}, nil} ->
        false

      {{:ok, %{cargo: cargo}}, component} ->
        installed? =
          match?({_, 0}, System.cmd(cargo, [component, "--version"], stderr_to_stdout: true))

        if installed? or System.get_env("CI"),
          do: false,
          else: "cargo #{component} is not installed (`rustup component add #{component}`)"
    end
  end

  @tag skip: unavailable.(nil)
  test "the tool's unit tests pass" do
    check!("test", ["test", "--locked", "--quiet"])
  end

  @tag skip: unavailable.("fmt")
  test "the sources are formatted as rustfmt formats them" do
    check!("fmt", ["fmt", "--check"])
  end

  @tag skip: unavailable.("clippy")
  test "clippy has nothing to say about the sources" do
    check!("clippy", ["clippy", "--locked", "--all-targets", "--", "-D", "warnings"])
  end

  defp check!(name, args) do
    {:ok, %{cargo: cargo, rustc_version: version}} = @rust
    key = :crypto.hash(:sha256, [Native.digest(), version]) |> Base.encode16(case: :lower)
    stamp = Path.join([@crate, "target", "argus-checks", "#{name}-#{binary_part(key, 0, 16)}"])

    unless File.exists?(stamp) do
      {output, status} =
        System.cmd(cargo, args,
          cd: @crate,
          stderr_to_stdout: true,
          env: [{"CARGO_TERM_COLOR", "never"}]
        )

      assert status == 0,
             "cargo #{Enum.join(args, " ")} in native/flowlog/tool exited #{status}:\n" <>
               tail(output)

      File.mkdir_p!(Path.dirname(stamp))
      File.write!(stamp, "")
    end
  end

  defp tail(output) do
    output |> String.split("\n") |> Enum.take(-80) |> Enum.join("\n")
  end
end
