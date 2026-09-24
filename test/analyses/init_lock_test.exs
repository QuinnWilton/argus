defmodule Argus.Analyses.InitLockTest do
  @moduledoc """
  The precision audit of startup's lock-during-init rule (2026-09-24),
  one regression per issue, with the controls that must keep their
  verdict (`Argus.Test.Fixtures.InitLock`).

  A lock init/1 holds is startup's finding; blocking steps aside for it
  (its `during_init` reads the same walk, `global_path`), so each lock is
  reported by one of the two, and a lock the walk sets aside becomes
  blocking's "Cluster-wide :global synchronization" again.
  """

  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Fixtures.InitLock

  @startup_titles [
    "Cluster-wide lock during init",
    "Lock during init",
    "Bounded cluster-wide lock during init"
  ]

  setup_all do
    unless Souffle.available?(), do: flunk("souffle not installed")

    modules = [
      InitLock.Bounded,
      InitLock.BoundedLocal,
      InitLock.DynamicRetries,
      InitLock.NoRetries,
      InitLock.TelemetryHandler,
      InitLock.TelemetryClosure,
      InitLock.StoredCallback,
      InitLock.EachClosure,
      InitLock.StartChildBeside,
      InitLock.WarmupBeside,
      InitLock.SpecClosure,
      InitLock.HelperStart,
      InitLock.SpawnedLock,
      InitLock.AwaitedTask,
      InitLock.UnawaitedTask,
      InitLock.SharedHelper,
      InitLock.SharedHelperEntered
    ]

    assert {:ok, %{findings: findings}} =
             Argus.run_analyses(modules, analyses: [:startup, :blocking])

    by_module =
      findings
      |> Enum.filter(&(&1.title in @startup_titles or &1.title =~ ":global"))
      |> Enum.group_by(fn f -> elem(f.mfa, 0) end)

    %{by_module: by_module}
  end

  defp lock_findings(by_module, mod), do: Map.get(by_module, mod, [])

  # The one startup lock finding for `mod`, and no blocking one beside it.
  defp init_lock(by_module, mod) do
    findings = lock_findings(by_module, mod)

    assert [f] = findings,
           "expected one lock finding for #{inspect(mod)}, got #{inspect(findings)}"

    assert f.analysis == :startup
    f
  end

  # init/1 does not hold the lock: blocking reports it, as a lock
  # outside init.
  defp not_init_lock(by_module, mod) do
    findings = lock_findings(by_module, mod)
    refute Enum.any?(findings, &(&1.title in @startup_titles)), inspect(findings)
    assert [%{analysis: :blocking, title: "Cluster-wide :global synchronization"}] = findings
  end

  describe "retries" do
    test "a positive count over the cluster is a bounded lock, a severity lower",
         %{by_module: by_module} do
      f = init_lock(by_module, InitLock.Bounded)
      assert f.title == "Bounded cluster-wide lock during init"
      assert f.severity == :warning
      assert f.at_label == "bounded cluster-wide lock reached from init/1"
      assert f.detail =~ "returns false"
      assert Enum.any?(f.related, &(&1.label == "init/1 reaches it from here"))
    end

    test "a positive count over [node()] is the fix the local finding recommends: quiet",
         %{by_module: by_module} do
      assert lock_findings(by_module, InitLock.BoundedLocal) == []
    end

    test "a count the bytecode does not show is assumed :infinity, and says so",
         %{by_module: by_module} do
      f = init_lock(by_module, InitLock.DynamicRetries)
      assert f.title == "Cluster-wide lock during init"
      assert f.severity == :error

      assert f.at_label ==
               "cluster-wide lock reached from init/1; its retry count could not be read, so assumed :infinity"

      assert f.detail =~ "assumes :infinity"
    end

    test "retries 0 tries once: quiet", %{by_module: by_module} do
      assert lock_findings(by_module, InitLock.NoRetries) == []
    end
  end

  describe "funs init/1 does not run" do
    test "a handler registered with :telemetry runs later, elsewhere", %{by_module: by_module} do
      not_init_lock(by_module, InitLock.TelemetryHandler)
      not_init_lock(by_module, InitLock.TelemetryClosure)
    end

    test "a fun kept in the state runs after init/1 has returned", %{by_module: by_module} do
      not_init_lock(by_module, InitLock.StoredCallback)
    end

    test "a closure handed to Enum.each runs on init's stack", %{by_module: by_module} do
      f = init_lock(by_module, InitLock.EachClosure)
      assert f.title == "Cluster-wide lock during init"
    end
  end

  describe "an unrelated process start" do
    test "a start_child beside an Enum.each does not set the closure aside",
         %{by_module: by_module} do
      f = init_lock(by_module, InitLock.StartChildBeside)
      assert f.title == "Cluster-wide lock during init"
    end

    test "a task on a fun from the options beside an Enum.each does not either",
         %{by_module: by_module} do
      f = init_lock(by_module, InitLock.WarmupBeside)
      assert f.title == "Cluster-wide lock during init"
    end

    test "a closure built into a child spec runs in the child", %{by_module: by_module} do
      not_init_lock(by_module, InitLock.SpecClosure)
    end

    test "a closure handed to a helper that starts a task runs in the task",
         %{by_module: by_module} do
      not_init_lock(by_module, InitLock.HelperStart)
    end

    test "a task init/1 starts and does not wait for", %{by_module: by_module} do
      not_init_lock(by_module, InitLock.SpawnedLock)
    end
  end

  describe "a task init/1 awaits" do
    test "Task.async then Task.await holds init for as long as the lock",
         %{by_module: by_module} do
      f = init_lock(by_module, InitLock.AwaitedTask)
      assert f.title == "Cluster-wide lock during init"
      assert Enum.any?(f.related, &(&1.label == "init/1 reaches it from here"))
    end

    test "a task awaited only in a later callback does not", %{by_module: by_module} do
      not_init_lock(by_module, InitLock.UnawaitedTask)
    end
  end

  describe "which clause init/1 enters" do
    test "a literal first argument enters only its clause", %{by_module: by_module} do
      not_init_lock(by_module, InitLock.SharedHelper)
    end

    test "startup reads the clauses on its own, without blocking's extractors" do
      assert {:ok, %{findings: findings}} =
               Argus.run_analyses([InitLock.SharedHelper], analyses: [:startup])

      refute Enum.any?(findings, &(&1.title in @startup_titles))
    end

    test "the clause init/1 enters is still reported", %{by_module: by_module} do
      f = init_lock(by_module, InitLock.SharedHelperEntered)
      assert f.title == "Cluster-wide lock during init"
    end
  end
end
