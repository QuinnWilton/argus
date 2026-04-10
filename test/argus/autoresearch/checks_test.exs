defmodule Argus.Autoresearch.ChecksTest do
  use ExUnit.Case, async: true

  alias Argus.Autoresearch.Checks

  @moduletag :tmp_dir

  describe "run_barrier/2 — passing commands" do
    test "returns :ok when all commands succeed" do
      commands = [
        ["true", []],
        ["true", []]
      ]

      assert :ok = Checks.run_barrier(commands)
    end

    test "calls on_step for each command start and completion" do
      pid = self()
      commands = [["true", []]]

      callback = fn step, status -> send(pid, {step, status}) end
      assert :ok = Checks.run_barrier(commands, callback)

      assert_received {{:command, ["true"]}, :start}
      assert_received {{:command, ["true"]}, {:done, :ok}}
    end
  end

  describe "run_barrier/2 — failing commands" do
    test "halts on first failure and returns the error" do
      commands = [
        ["true", []],
        ["false", []],
        ["true", []]
      ]

      assert {:error, {:command_failed, ["false"], 1, _tail}} = Checks.run_barrier(commands)
    end

    test "doesn't execute later commands after a failure" do
      pid = self()

      commands = [
        ["false", []],
        # This command would send a message if executed.
        ["sh", ["-c", "true"]]
      ]

      callback = fn step, status -> send(pid, {step, status}) end
      assert {:error, _} = Checks.run_barrier(commands, callback)

      # The second command should not have started.
      assert_received {{:command, ["false"]}, :start}
      assert_received {{:command, ["false"]}, {:done, {:error, _}}}
      refute_received {{:command, ["sh", "-c", "true"]}, :start}
    end

    test "captures command output tail in the failure" do
      commands = [["sh", ["-c", "echo some_error_output && exit 2"]]]

      assert {:error, {:command_failed, _, 2, output}} = Checks.run_barrier(commands)
      assert output =~ "some_error_output"
    end

    test "handles nonexistent commands gracefully" do
      commands = [["absolutely_no_such_command_xyz123", []]]

      assert {:error, {:command_failed, _, 127, msg}} = Checks.run_barrier(commands)
      assert msg =~ "failed to execute"
    end
  end

  describe "canary fixture comparison" do
    # compare_canary is private but we can exercise it via run_canary
    # by mocking the baseline and skipping the measurement. Instead,
    # test the whole capture/compare flow via a fake baseline setup.

    test "canary drift detection requires a baseline and canary project",
         %{tmp_dir: tmp_dir} do
      # When no baseline fixture exists, run_canary returns :no_canary.
      config = %Argus.Autoresearch.Config{
        corpus_root: tmp_dir,
        tiers: %{"fast" => []},
        default_tier: "fast",
        canary_project: "poolboy"
      }

      assert {:error, :no_canary} = Checks.run_canary(config, baseline_dir: tmp_dir)
    end

    test "canary cross-check skips when no canary is configured" do
      config = %Argus.Autoresearch.Config{
        corpus_root: "/tmp",
        tiers: %{"fast" => []},
        default_tier: "fast",
        canary_project: nil
      }

      assert {:error, :no_canary_configured} = Checks.run_canary(config)
    end
  end

  describe "run/2 — integration with config" do
    test "passes when barrier commands succeed and no canary is configured" do
      config = %Argus.Autoresearch.Config{
        corpus_root: "/tmp",
        tiers: %{"fast" => []},
        default_tier: "fast",
        canary_project: nil,
        checks_barrier: [["true", []]]
      }

      assert :ok = Checks.run(config: config, skip_canary: true)
    end

    test "fails when a barrier command fails" do
      config = %Argus.Autoresearch.Config{
        corpus_root: "/tmp",
        tiers: %{"fast" => []},
        default_tier: "fast",
        canary_project: nil,
        checks_barrier: [["true", []], ["false", []]]
      }

      assert {:error, {:command_failed, ["false"], 1, _}} =
               Checks.run(config: config, skip_canary: true)
    end

    test "emits on_step events for each barrier command and canary" do
      pid = self()
      callback = fn step, status -> send(pid, {step, status}) end

      config = %Argus.Autoresearch.Config{
        corpus_root: "/tmp",
        tiers: %{"fast" => []},
        default_tier: "fast",
        canary_project: nil,
        checks_barrier: [["true", []]]
      }

      assert :ok = Checks.run(config: config, on_step: callback, skip_canary: true)
      assert_received {{:command, ["true"]}, :start}
      assert_received {{:command, ["true"]}, {:done, :ok}}
    end
  end
end
