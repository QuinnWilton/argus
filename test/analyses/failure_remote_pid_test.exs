defmodule Argus.Analyses.FailureRemotePidTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Failure
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.RemotePid
  alias Argus.Test.Rows

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    RemotePid.GlobalAlive,
    RemotePid.NodeGuarded,
    RemotePid.Rescued,
    RemotePid.Resolver,
    RemotePid.SynHandler,
    RemotePid.Members,
    RemotePid.Helper,
    RemotePid.CallerRescues,
    RemotePid.MiddleRescue,
    RemotePid.Names,
    RemotePid.Links
  ]

  setup_all do
    %{batch: Batch.solve(:failure, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # `{function, anchor, site, bif, api, kind}` with the fixture prefix
  # dropped from the function.
  defp probes(%{batch: batch}, module) do
    assert {:ok, results} = Batch.analyze(batch, [module])

    for [func, anchor, site, bif, api, kind] <-
          Rows.where(results, :failure, "remote_pid_probe", []) do
      short = String.replace(func, "Argus.Test.Fixtures.RemotePid.", "")
      {short, anchor == site, bif, api, kind}
    end
  end

  defp funcs(rows), do: rows |> Enum.map(&elem(&1, 0)) |> Enum.sort()

  describe "remote_pid_probe" do
    test "a :global lookup's pid handed to Process.alive?/1 (aprs.me before 37c9ac7)", ctx do
      skip_without_souffle()

      assert [
               {"GlobalAlive:cleanup/1", true, ":erlang.is_process_alive/1",
                ":global.whereis_name/1", "lookup"}
             ] = probes(ctx, RemotePid.GlobalAlive)
    end

    test "a probe on the arm where node(pid) is this node is cleared; the other arm, a join or another pid is not",
         ctx do
      skip_without_souffle()

      assert funcs(probes(ctx, RemotePid.NodeGuarded)) == [
               "NodeGuarded:asked_before/1",
               "NodeGuarded:else_arm/1",
               "NodeGuarded:other_node/2",
               "NodeGuarded:unless_local/1",
               "NodeGuarded:when_remote/1"
             ]
    end

    test "a rescue of ArgumentError that goes on clears it; a re-raise, an after, another exception or another call's rescue does not",
         ctx do
      skip_without_souffle()

      assert funcs(probes(ctx, RemotePid.Rescued)) == [
               "Rescued:after_only/1",
               "Rescued:other_call/1",
               "Rescued:reraises/1",
               "Rescued:wrong_rescue/1"
             ]
    end

    test "a conflict resolver's pids are another node's by construction (aprs.me before 9212088)",
         ctx do
      skip_without_souffle()

      rows = probes(ctx, RemotePid.Resolver)

      assert funcs(rows) == ["Resolver:resolve_conflict/3", "Resolver:resolve_conflict/3"]

      assert Enum.all?(
               rows,
               &match?({_, true, "Process.info/2", ":global.register_name/3", "resolver"}, &1)
             )
    end

    test "syn's resolve_registry_conflict/4 is handed each holder in a tuple", ctx do
      skip_without_souffle()

      assert [
               {"SynHandler:resolve_registry_conflict/4", true, ":erlang.is_process_alive/1", _,
                "resolver"}
             ] = probes(ctx, RemotePid.SynHandler)
    end

    test "a process group's members, by a captured BIF and in a comprehension", ctx do
      skip_without_souffle()

      rows = probes(ctx, RemotePid.Members)

      assert {"Members:live/1", true, ":erlang.is_process_alive/1", ":pg.get_members/2", "lookup"} in rows

      assert Enum.any?(
               rows,
               &match?(
                 {"Members:-sizes/1-fun-0-/" <> _, true, "Process.info/2", ":pg.get_members/1",
                  _},
                 &1
               )
             )

      refute Enum.any?(rows, &match?({"Members:local/1", _, _, _, _}, &1))
    end

    test "a helper's probe of its parameter is the caller's, at the call into it", ctx do
      skip_without_souffle()

      assert [
               {"Helper:leader_alive?/1", false, ":erlang.is_process_alive/1",
                ":global.whereis_name/1", "lookup"}
             ] = probes(ctx, RemotePid.Helper)
    end

    test "a private probe whose every caller rescues the badarg is quiet", ctx do
      skip_without_souffle()
      assert probes(ctx, RemotePid.CallerRescues) == []
    end

    test "a rescue around a call between the helpers takes the badarg; one around other code does not",
         ctx do
      skip_without_souffle()

      assert [
               {"MiddleRescue:leader_seen?/1", false, ":erlang.is_process_alive/1",
                ":global.whereis_name/1", "lookup"}
             ] = probes(ctx, RemotePid.MiddleRescue)
    end

    test "a process's links, reordered and walked (phoenix_live_dashboard before 57e8a1f)", ctx do
      skip_without_souffle()

      assert [
               {"Links:-children/2-fun-0-/" <> _, false, "Process.info/2", "Process.info/2",
                "lookup"}
             ] =
               probes(ctx, RemotePid.Links)
    end

    test "GenServer.whereis/1 of a :global name and a lookup a helper returns; a Registry's is quiet",
         ctx do
      skip_without_souffle()

      assert funcs(probes(ctx, RemotePid.Names)) == ["Names:global_info/1", "Names:leader_info/0"]
    end
  end

  describe "remote_pid_probe prose" do
    test "a resolver's is an error, a lookup's a warning; the title names neither" do
      resolver =
        Failure.finding(:remote_pid_probe, [
          "M:f/3",
          "M:f/3#4",
          "M:f/3#4",
          "Process.info/2",
          ":global.register_name/3",
          "resolver"
        ])

      lookup =
        Failure.finding(:remote_pid_probe, [
          "M:g/1",
          "M:g/1#2",
          "M:h/1#3",
          ":erlang.is_process_alive/1",
          ":global.whereis_name/1",
          "lookup"
        ])

      assert resolver.severity == :error
      assert lookup.severity == :warning
      assert resolver.title == lookup.title
      refute lookup.title =~ "alive"
      assert lookup.detail =~ ":global.whereis_name/1"
      assert [%{label: "the local-only call"}] = lookup.related
    end
  end
end
