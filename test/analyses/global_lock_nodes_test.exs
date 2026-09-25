defmodule Argus.Analyses.GlobalLockNodesTest do
  @moduledoc """
  Whose agreement a `:global` lock waits on decides what startup and
  blocking say about it. A lock over the connected nodes (or an omitted
  list, which means every known node) is cluster-wide; one over
  `[node()]` waits only on this node's holders and is a lock during
  init, one severity lower; one whose list the bytecode does not show
  is reported as cluster-wide, saying so.
  """

  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Fixtures.GlobalNodes
  alias Argus.Test.Fixtures.ReachPath
  alias Argus.Test.Memo

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp findings(modules, analysis) do
    assert {:ok, %{findings: findings}} =
             Memo.run_analyses(modules, analyses: [analysis])

    findings
  end

  # The one :global finding startup reports for `mod`.
  defp init_lock(mod) do
    [f] =
      mod
      |> List.wrap()
      |> findings(:startup)
      |> Enum.filter(&(&1.title in ["Cluster-wide lock during init", "Lock during init"]))

    f
  end

  describe "startup: a lock during init" do
    test "[node() | Node.list()] is cluster-wide" do
      skip_without_souffle()

      f = init_lock(GlobalNodes.Cluster)
      assert f.title == "Cluster-wide lock during init"
      assert f.severity == :error
      assert f.at_label == "cluster-wide lock reached from init/1"
    end

    test "set_lock/1, with no node list, is cluster-wide" do
      skip_without_souffle()

      f = init_lock(GlobalNodes.Default)
      assert f.title == "Cluster-wide lock during init"
      assert f.severity == :error
      assert f.at_label == "cluster-wide lock reached from init/1"
    end

    test "[node()] is a lock during init, one severity lower" do
      skip_without_souffle()

      f = init_lock(GlobalNodes.Local)
      assert f.title == "Lock during init"
      assert f.severity == :warning
      assert f.at_label =~ "this node's holders"
      refute f.detail =~ "cluster-wide"
    end

    test "a node list passed in stays cluster-wide and says it was not read" do
      skip_without_souffle()

      f = init_lock(GlobalNodes.Unknown)
      assert f.title == "Cluster-wide lock during init"
      assert f.severity == :error
      assert f.at_label =~ "node list could not be read"
      assert f.detail =~ "assumes"
    end
  end

  describe "startup: the talk's lesson" do
    test "ClusterLock, [node() | Node.list()], is cluster-wide" do
      skip_without_souffle()

      f = init_lock(ReachPath.ClusterLock)
      assert f.title == "Cluster-wide lock during init"
      assert f.at_label == "cluster-wide lock reached from init/1"
      assert Enum.any?(f.related, &(&1.label == "init/1 reaches it from here"))
    end

    test "the same lesson over [node()] is a lock during init" do
      skip_without_souffle()

      f = init_lock(ReachPath.LocalLock)
      assert f.title == "Lock during init"
      assert f.severity == :warning
      assert Enum.any?(f.related, &(&1.label == "init/1 reaches it from here"))
    end
  end

  describe "blocking: a lock outside init" do
    setup do
      skip_without_souffle()

      by_func =
        [GlobalNodes.Shapes]
        |> findings(:blocking)
        |> Map.new(fn f -> {elem(f.mfa, 1), f} end)

      %{by_func: by_func}
    end

    test "a cluster lock is cluster-wide synchronization", %{by_func: by_func} do
      assert by_func[:cluster].title == "Cluster-wide :global synchronization"
      assert by_func[:cluster].at_label == "cluster-wide operation"
      assert by_func[:default].title == "Cluster-wide :global synchronization"
    end

    test "a local lock is not called cluster-wide", %{by_func: by_func} do
      assert by_func[:local].title == "Local :global lock without a retry bound"
      refute by_func[:local].detail =~ "whole cluster"
    end

    test "an unread list stays cluster-wide and says so", %{by_func: by_func} do
      assert by_func[:arg].title == "Cluster-wide :global synchronization"
      assert by_func[:arg].at_label =~ "node list could not be read"
    end

    # The terms startup reports a lock during init/1 on
    # (clientlib/vocabulary.dl): a count the bytecode does not show is
    # assumed :infinity, and a bounded count over [node()] is the fix.
    test "an unread retry count is assumed :infinity", %{by_func: by_func} do
      assert by_func[:forwarded_retries].title == "Cluster-wide :global synchronization"
      assert by_func[:forwarded_retries].detail =~ "assumed :infinity"
    end

    test "a bounded lock over the cluster still asks every node; over [node()] it is quiet",
         %{by_func: by_func} do
      assert by_func[:bounded_cluster].title == "Bounded cluster-wide :global lock"
      assert by_func[:trans_cluster].title == "Bounded cluster-wide :global lock"
      refute Map.has_key?(by_func, :bounded_local)
    end
  end
end
