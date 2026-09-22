defmodule Argus.Analyses.ShutdownTest do
  use ExUnit.Case

  alias Argus.Souffle
  alias Argus.Test.Fixtures.Shutdown, as: S

  @all [
    S.Leaks,
    S.Traps,
    S.LeaksIndirect,
    S.LogsOnly,
    S.ReadsOnly,
    S.Unclear,
    S.UnclearTraps,
    S.Lease,
    S.Truncatable,
    S.CleansUpElsewhere
  ]

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp results do
    assert {:ok, r} = Argus.analyze(@all, :shutdown)
    r
  end

  defp rows(r, relation), do: Map.get(r, relation, [])

  defp modules(r, relation),
    do: r |> rows(relation) |> Enum.map(&hd/1) |> Enum.uniq() |> Enum.sort()

  defp named?(mods, fragment), do: Enum.any?(mods, &String.contains?(&1, fragment))

  # Matches the module column exactly. `Shutdown.Leaks` is a prefix of
  # `Shutdown.LeaksIndirect`, so a contains-check would silently conflate
  # the two positives and let either one satisfy both tests.
  defp only(r, relation, suffix) do
    r |> rows(relation) |> Enum.filter(&String.ends_with?(hd(&1), suffix))
  end

  describe "terminate_calls_sibling" do
    test "a call to a sibling from terminate/2 is reported; a cast is not" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ShutdownSiblings, as: Sib

      {:ok, r} =
        Argus.analyze(
          [Sib.Sup, Sib.Producer, Sib.Watchman, Sib.CarefulWatchman],
          :shutdown
        )

      pairs =
        r
        |> rows("terminate_calls_sibling")
        |> Enum.map(fn [mod, sib, _via, _sup] -> {mod, sib} end)
        |> Enum.uniq()

      assert pairs == [
               {"Argus.Test.Fixtures.ShutdownSiblings.Watchman",
                "Argus.Test.Fixtures.ShutdownSiblings.Producer"}
             ]
    end
  end

  describe "foreign_dynamic_children" do
    test "children started under another tree are reported unless terminate/2 stops them" do
      skip_without_souffle()
      alias Argus.Test.Fixtures.ForeignChildren, as: F

      {:ok, r} =
        Argus.analyze(
          [
            F.LibraryTree,
            F.AppTree,
            F.Worker,
            F.Manager,
            F.TidyManager,
            F.TaskTree,
            F.TaskStarter
          ],
          :shutdown
        )

      assert modules(r, "foreign_dynamic_children") == [
               "Argus.Test.Fixtures.ForeignChildren.Manager",
               "Argus.Test.Fixtures.ForeignChildren.TaskStarter"
             ]
    end
  end

  describe "detection" do
    test "durable cleanup without trap_exit is reported" do
      skip_without_souffle()

      assert [[mod, behaviour, "io", api, via]] =
               only(results(), "cleanup_never_runs", "Shutdown.Leaks")

      assert mod =~ "Shutdown.Leaks"
      assert behaviour == "GenServer"
      assert api =~ "write"
      assert via =~ "terminate"
    end

    test "cleanup several calls below terminate/2 is attributed to its site" do
      skip_without_souffle()

      assert [[_mod, _b, "io", _api, via]] =
               only(results(), "cleanup_never_runs", "LeaksIndirect")

      assert via =~ "persist", "blamed terminate/2 rather than the function at fault"
    end

    test "unclassified work in terminate/2 is reported separately" do
      skip_without_souffle()

      mods = modules(results(), "cleanup_unclear")

      assert named?(mods, "Shutdown.Unclear"),
             "a call into the application's own code is where most cleanup lives"

      refute named?(mods, "UnclearTraps"), "trapping means the callback is reached"
    end

    test "unbounded work is reported when the module does trap" do
      skip_without_souffle()

      assert [[mod, _b, "network", api, _via]] = rows(results(), "terminate_may_be_truncated")
      assert mod =~ "Truncatable"
      assert api =~ "request"
    end
  end

  describe "the claim is the missing trap, not the cleanup" do
    # Every positive above has a twin that does identical work while
    # trapping. If those twins were also reported, the analysis would be
    # detecting "has a terminate/2" and nothing else.
    test "the same cleanup is not reported when the module traps exits" do
      skip_without_souffle()

      mods = modules(results(), "cleanup_never_runs")

      assert named?(mods, "Shutdown.Leaks")
      refute named?(mods, "Shutdown.Traps"), "trapping means terminate/2 actually runs"
    end
  end

  describe "evidence quality" do
    # The verdict being right is not enough if the evidence is wrong. An
    # earlier version used the unbounded call_reachable closure and credited
    # Sequin's MutexOwner with `:ets.insert/2 via :wpool_pool:store_wpool/1`
    # — connection-pool internals five hops down Mutex.release -> Redis ->
    # wpool. Right module, meaningless witness, and indistinguishable from
    # luck until read against source.
    test "cleanup is attributed within a few hops of terminate/2" do
      skip_without_souffle()

      assert [[_mod, _b, "io", api, via]] =
               only(results(), "cleanup_never_runs", "LeaksIndirect")

      assert via =~ "persist", "two hops is inside the bound"
      assert api =~ "write"
    end
  end

  describe "what is deliberately not reported" do
    test "logging is not cleanup" do
      skip_without_souffle()
      r = results()

      refute named?(modules(r, "cleanup_never_runs"), "LogsOnly")
      refute named?(modules(r, "cleanup_unclear"), "LogsOnly")
    end

    test "reads have nothing to lose by being skipped" do
      skip_without_souffle()
      r = results()

      refute named?(modules(r, "cleanup_never_runs"), "ReadsOnly")
      refute named?(modules(r, "cleanup_unclear"), "ReadsOnly")
    end

    test "cleanup outside terminate/2 is not this analysis's business" do
      skip_without_souffle()

      refute named?(modules(results(), "cleanup_never_runs"), "CleansUpElsewhere")
    end

    test "a module with classified cleanup is not also reported as unclear" do
      skip_without_souffle()

      # Otherwise the precise finding and the vague one would name the same
      # module, and the vague one adds nothing.
      assert named?(modules(results(), "cleanup_never_runs"), "Shutdown.Leaks")
      refute named?(modules(results(), "cleanup_unclear"), "Shutdown.Leaks")
    end
  end

  describe "findings" do
    test "each relation renders a finding naming the module and the fix" do
      mod = Argus.Analyses.Shutdown

      never =
        mod.finding(:cleanup_never_runs, ["My.Server", "GenServer", "io", "File.write/2", "f"])

      assert never.severity == :error
      assert never.detail =~ "trap_exit"
      assert never.detail =~ "file I/O"

      unclear = mod.finding(:cleanup_unclear, ["My.Server", "GenServer", "Lease.release/1", "f"])
      assert unclear.severity == :warning
      assert unclear.detail =~ "cannot classify"

      trunc_ =
        mod.finding(:terminate_may_be_truncated, [
          "My.Server",
          "GenServer",
          "network",
          "httpc.request/1",
          "f"
        ])

      assert trunc_.severity == :warning
      assert trunc_.detail =~ "shutdown timeout"
    end
  end
end
