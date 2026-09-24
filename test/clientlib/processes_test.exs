defmodule Argus.Clientlib.ProcessesTest do
  use ExUnit.Case, async: true

  alias Argus.{Analysis, Pipeline, Souffle}
  alias Argus.Test.Fixtures.PidFlow

  @modules [
    PidFlow.Worker,
    PidFlow.Owner,
    PidFlow.Loops,
    PidFlow.CycleA,
    PidFlow.CycleB,
    PidFlow.Tree,
    PidFlow.Kid,
    PidFlow.Starter,
    PidFlow.Hub,
    PidFlow.Listener,
    PidFlow.Front,
    PidFlow.Back,
    PidFlow.Side,
    PidFlow.Relay,
    PidFlow.Subscriber,
    PidFlow.SafeCall,
    PidFlow.UserA,
    PidFlow.UserB,
    PidFlow.TargetA,
    PidFlow.TargetB,
    PidFlow.Timed,
    PidFlow.Starts,
    PidFlow.Names,
    PidFlow.NamedTree,
    PidFlow.SelfHelper,
    PidFlow.Machine,
    PidFlow.Keeper,
    PidFlow.KeeperClient,
    PidFlow.Directory,
    PidFlow.DirectoryClient,
    PidFlow.Carrier,
    PidFlow.Conn,
    PidFlow.ConnUser,
    PidFlow.ConnSup,
    PidFlow.Joiner,
    PidFlow.Reindexer,
    PidFlow.AnyCall,
    PidFlow.Decoy,
    PidFlow.Answerer,
    PidFlow.ProxyApi,
    PidFlow.ProxyUser,
    PidFlow.NamedCall,
    PidFlow.NamedUserA,
    PidFlow.NamedUserB,
    PidFlow.NamedTargetA,
    PidFlow.NamedTargetB,
    PidFlow.StatemClient,
    PidFlow.Quiet
  ]

  defp priv_dl, do: Path.join(:code.priv_dir(:panoptes), "dl")

  # The relations of processes.dl the points-to stage does not stage.
  @internal ~w(param_pts returns_pts self_pid statem_data_pts)

  # Every relation a test below reads. One extraction and one solve per
  # program serve the module: the rows of a relation do not depend on
  # which others a program outputs, and each test only reads them.
  @outputs ~w(async_dep call_site_target call_target exit_to_own_process genserver_sync_api
              instance named_pid param_pts private_process process_call process_start
              reaches_sync_dep returns_pts self_call self_pid send_target server_process
              signal_target statem_data_pts supervised_process sync_dep sync_dep_timeout
              sync_site tag_resolved_site watched_process)

  setup_all do
    unless Souffle.available?(), do: flunk("souffle not installed")

    dir = Path.join(System.tmp_dir!(), "argus_processes_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    facts_dir = Path.join(dir, "facts")

    {:ok, _} =
      Pipeline.run(@modules, facts_dir,
        extractors: [
          Argus.Extractors.OTP,
          Argus.Extractors.ApiCalls,
          Argus.Extractors.CallbackTag,
          Argus.Extractors.ProcessRegistry,
          Argus.Extractors.Supervision,
          Argus.Extractors.GenStatem,
          Argus.Extractors.PidFlow,
          Argus.Extractors.CallArgs
        ]
      )

    :ok = Analysis.derive_stage0(facts_dir)
    :ok = Analysis.derive_points_to(facts_dir)

    # What the stage keeps to itself is asked of its own program; what it
    # stages, of the program the analyses include.
    {internal, staged} = Enum.split_with(@outputs, &(&1 in @internal))

    results =
      Map.merge(
        run(dir, facts_dir, "internal.dl", internal, """
        .include "#{Analysis.points_to_rules_path()}"
        """),
        run(dir, facts_dir, "staged.dl", staged, """
        .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
        .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
        .include "#{Path.join(priv_dl(), "clientlib/process_statem.dl")}"
        .include "#{Path.join(priv_dl(), "clientlib/sends.dl")}"
        .include "#{Path.join(priv_dl(), "clientlib/signals.dl")}"
        """)
      )

    %{
      results:
        Map.new(results, fn {relation, rows} ->
          {relation, Enum.map(rows, fn row -> Enum.map(row, &short/1) end)}
        end)
    }
  end

  defp solve(%{results: results}, outputs) do
    for relation <- outputs, not Map.has_key?(results, relation) do
      flunk("#{relation} is not solved: add it to @outputs")
    end

    Map.take(results, outputs)
  end

  defp run(dir, facts_dir, name, outputs, includes) do
    rules_path = Path.join(dir, name)
    File.write!(rules_path, includes <> Enum.map_join(outputs, "\n", &".output #{&1}"))
    output_dir = Path.join(dir, Path.rootname(name))
    File.mkdir_p!(output_dir)
    # A program of its own output directory: the stage's `.output`s write
    # files named like the facts, which must not land in facts_dir.
    {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: output_dir)
    Map.take(results, outputs)
  end

  defp short(s), do: String.replace(s, "Argus.Test.Fixtures.PidFlow.", "")

  # A process id with its site dropped: "server Worker:start_link/1#6" is
  # "server Worker:start_link/1".
  defp unsite(id), do: String.replace(id, ~r/#\d+$/, "")

  defp unsited(rows), do: Enum.map(rows, fn row -> Enum.map(row, &unsite/1) end)

  test "a pid follows a wrapper's result and two parameters to a cast", ctx do
    r = solve(ctx, ~w(returns_pts param_pts call_target))

    # Worker.start_link is a factory: the process Owner.run keeps is its own.
    assert ["Worker:ping/1", "0", "start Owner:run/0"] in unsited(r["param_pts"])
    assert ["Owner:relay/1", "0", "start Owner:run/0"] in unsited(r["param_pts"])
    # Owner.run hands the pid down two helpers to Worker.notify's cast: the
    # cast is Owner.run's, not the helpers'.
    assert ["Owner:run/0", "cast", "start Owner:run/0"] in unsited(r["call_target"])
    refute Enum.any?(r["call_target"], &match?(["Worker:notify/1" | _], &1))

    assert ["Owner:across_a_call/0", "call", "server Owner:across_a_call/0"] in unsited(
             r["call_target"]
           )
  end

  test "resolved calls become dependencies on the server's module", ctx do
    r = solve(ctx, ~w(sync_dep async_dep))

    assert ["Owner:direct/0", "Worker"] in r["sync_dep"]
    assert ["Owner:run/0", "Worker"] in r["sync_dep"]
    assert ["Owner:run/0", "Worker"] in r["async_dep"]
  end

  test "a helper's parameter is each caller's pid, not all of them", ctx do
    r = solve(ctx, ~w(sync_dep process_call sync_site))
    deps = for ["User" <> _ = f, m] <- r["sync_dep"], do: {f, m}

    assert {"UserA:handle_call/3", "TargetA"} in deps
    assert {"UserB:handle_call/3", "TargetB"} in deps
    refute {"UserA:handle_call/3", "TargetB"} in deps
    refute {"UserB:handle_call/3", "TargetA"} in deps
    # Neither helper holds a dependency of its own.
    refute Enum.any?(r["sync_dep"], &match?(["SafeCall:" <> _, _], &1))

    # The dependency is anchored at UserA's call into the helper, and
    # also names the helper's GenServer.call it comes down to.
    for [f, anchor, site, "call", _p] <- r["process_call"], f == "UserA:handle_call/3" do
      assert String.starts_with?(anchor, "UserA:handle_call/3#")
      assert String.starts_with?(site, "SafeCall:")
    end

    assert Enum.any?(
             r["sync_site"],
             &match?(["UserA:handle_call/3", "TargetA", "UserA:" <> _], &1)
           )
  end

  test "a dependency carries the timeout of the call that makes it", ctx do
    r = solve(ctx, ~w(sync_dep_timeout))
    timeouts = for ["Timed:handle_call/3", m, ms] <- r["sync_dep_timeout"], do: {m, ms}

    assert {"TargetA", "-1"} in timeouts
    refute {"TargetA", "5000"} in timeouts
  end

  test "self() and a server's state carry a peer's pid", ctx do
    r = solve(ctx, ~w(param_pts sync_dep))
    params = unsited(r["param_pts"])

    # A starts B with self(): B's init/1, and so B's state, holds A.
    assert ["CycleB:init/1", "0", "server CycleA:start_link/1"] in params
    assert ["CycleB:handle_call/3", "2", "server CycleA:start_link/1"] in params
    # A keeps B's pid, returned from init/1 in {:ok, pid}, as its state.
    assert ["CycleA:handle_call/3", "2", "server CycleB:start_link/1"] in params
    assert ["CycleA:handle_call/3", "CycleB"] in r["sync_dep"]
    assert ["CycleB:handle_call/3", "CycleA"] in r["sync_dep"]
  end

  test "each pid in a state map stays under its key", ctx do
    r = solve(ctx, ~w(call_target sync_dep))

    # Front holds both Back and Side, and calls only Back.
    assert ["Front:handle_call/3", "call", "start Front:init/1"] in unsited(r["call_target"])

    refute Enum.any?(
             r["call_target"],
             &match?(["Front:handle_call/3", _, "server Side" <> _], &1)
           )

    assert ["Front:handle_call/3", "Back"] in r["sync_dep"]
    refute ["Front:handle_call/3", "Side"] in r["sync_dep"]
  end

  test "a list field and a scalar field of one state reach different processes",
       ctx do
    r = solve(ctx, ~w(send_target))
    sends = for [_, "Relay:handle_info/2", m, p] <- r["send_target"], do: {m, unsite(p)}

    assert {":event", "spawn Subscriber:go/0"} in sends
    assert {":flush", "spawn Relay:init/1"} in sends
    refute {":event", "spawn Relay:init/1"} in sends
  end

  test "a registered name and a captured pid route sends", ctx do
    r = solve(ctx, ~w(named_pid send_target))

    assert [":loops", "spawn Loops:start/0"] in unsited(r["named_pid"])

    assert Enum.any?(
             unsited(r["send_target"]),
             &match?([_, "Loops:start/0", ":tick", "spawn Loops:start/0"], &1)
           )

    assert Enum.any?(
             unsited(r["send_target"]),
             &match?([_, "Loops:-start/0-fun-0-/1", "{:done, …}", "spawn Loops:start/0"], &1)
           )
  end

  test "a child a supervisor starts on request is a process its caller holds",
       ctx do
    r = solve(ctx, ~w(call_target))
    assert ["Owner:dynamic/0", "call", "server Owner:dynamic/0"] in unsited(r["call_target"])
  end

  test "a GenServer a child spec names is a server, so self() in it resolves",
       ctx do
    # Kid starts through a helper with a computed module: no start call in
    # the program names it, only Tree's child spec.
    r = solve(ctx, ~w(self_pid process_start))
    refute Enum.any?(r["process_start"], &(Enum.at(&1, 4) == "Kid"))
    assert ["Kid:init/1", "child Tree#0"] in r["self_pid"]
  end

  test "a pid in a cast's message reaches the handler and the server's state",
       ctx do
    r = solve(ctx, ~w(param_pts call_target))
    params = unsited(r["param_pts"])

    assert ["Hub:subscribe/1", "0", "server Listener:start_link/1"] in params
    assert Enum.any?(params, &match?(["Hub:handle_cast/2", "0", "Hub:subscribe/1"], &1))

    assert ["Hub:handle_call/3", "call", "server Listener:start_link/1"] in unsited(
             r["call_target"]
           )
  end

  test "starts beyond start_link are processes", ctx do
    r = solve(ctx, ~w(call_site_target send_target process_start))
    targets = for [_, f, kind, p] <- unsited(r["call_site_target"]), do: {f, kind, p}

    # {:ok, {pid, ref}} from start_monitor, a Task's pid, an Agent.
    assert {"Starts:monitored/0", "call", "server Starts:monitored/0"} in targets
    assert {"Starts:tasks/0", "info", "spawn Starts:tasks/0"} in targets
    assert {"Starts:agent/0", "call", "agent Starts:agent/0"} in targets

    # A task runs its closure; a send to it is judged against that receive.
    assert Enum.any?(
             r["process_start"],
             &match?([_, "Starts:tasks/0", _, "spawn", "Starts:-tasks/0-fun-" <> _], &1)
           )
  end

  test "a pid in a function's sixth parameter", ctx do
    r = solve(ctx, ~w(param_pts))
    assert ["Starts:seven/7", "5", "spawn Starts:wide/0"] in unsited(r["param_pts"])
  end

  test "names live in three registries and a child spec", ctx do
    r = solve(ctx, ~w(named_pid call_site_target))
    names = unsited(r["named_pid"])

    assert ["{:global, :names}", "server Names:start_link/1"] in names
    assert ["{:via, Registry, {Reg, :names}}", "server Names:start_link/1"] in names
    assert [":counter", "agent Starts:agent/0"] in names
    assert [":named_worker", "child NamedTree#0"] in r["named_pid"]

    for f <- ~w(Names:ping_global/0 Names:ping_whereis/0 Names:ping_registry/0) do
      assert [f, "call", "server Names:start_link/1"] in for(
               [_, f, k, p] <- unsited(r["call_site_target"]),
               do: [f, k, p]
             )
    end
  end

  test "a registration of another pid names that pid, not the caller's module",
       ctx do
    r = solve(ctx, ~w(named_pid))
    # Names spawns a helper and registers it: ProcessRegistry's
    # module-level guess says Names' own process holds the name.
    assert for([":names_helper", p] <- unsited(r["named_pid"]), do: p) ==
             ["spawn Names:park/0"]
  end

  test "self() in a helper is the process that calls it", ctx do
    r = solve(ctx, ~w(self_pid send_target))

    assert ["SelfHelper:remind/0", "spawn SelfHelper:start/0"] in unsited(r["self_pid"])

    assert Enum.any?(
             unsited(r["send_target"]),
             &match?([_, "SelfHelper:remind/0", ":reminder", "spawn SelfHelper:start/0"], &1)
           )
  end

  test "self() in a closure is the process that runs it", ctx do
    r = solve(ctx, ~w(self_pid))

    procs = fn pattern ->
      for [f, p] <- unsited(r["self_pid"]), f =~ pattern, into: MapSet.new(), do: p
    end

    # Enum.each runs its closure in init's process: the server.
    assert procs.(~r/^Joiner:-init\/1-fun-\d-\/1$/) == MapSet.new(["server Joiner:start_link/1"])
    # Task.start runs its closure in the task, and only there.
    assert procs.(~r/^Joiner:-init\/1-fun-\d-\/0$/) == MapSet.new(["spawn Joiner:init/1"])
  end

  test "a call points-to resolves is not attributed by its tag", ctx do
    r = solve(ctx, ~w(sync_dep tag_resolved_site))

    # :reindex is named by Decoy alone, but the call goes to the AnyCall
    # Reindexer started.
    assert ["Reindexer:handle_call/3", "AnyCall"] in r["sync_dep"]
    refute ["Reindexer:handle_call/3", "Decoy"] in r["sync_dep"]
    refute Enum.any?(r["tag_resolved_site"], &match?([_, "Reindexer:handle_call/3" | _], &1))
  end

  test "a server module's function that calls another server is a proxy", ctx do
    r = solve(ctx, ~w(sync_dep reaches_sync_dep genserver_sync_api))

    # ProxyApi.ask/0 calls Answerer by name: ProxyUser waits on Answerer,
    # and ask/0 is not ProxyApi's own client API.
    refute Enum.any?(r["genserver_sync_api"], &match?(["ProxyApi:ask/0", _], &1))
    refute ["ProxyUser:use/0", "ProxyApi"] in r["sync_dep"]
    assert ["ProxyUser:use/0", "Answerer"] in r["reaches_sync_dep"]
  end

  test "a wrapper forwarding its target to :gen_statem.call is a peer call", ctx do
    r = solve(ctx, ~w(sync_dep))
    # The caller that names Machine waits on it, not the wrapper it hands
    # the name to.
    assert ["StatemClient:status/0", "Machine"] in r["sync_dep"]
    refute ["StatemClient:do_call/2", "Machine"] in r["sync_dep"]
  end

  test "a name handed to a wrapper is the target of the call that hands it", ctx do
    r = solve(ctx, ~w(sync_dep reaches_sync_dep sync_site))

    # Each caller waits on the server it names, through the helper or its
    # wrapper, and on no other caller's: the helper waits on none.
    assert ["NamedUserA:handle_call/3", "NamedTargetA"] in r["sync_dep"]
    assert ["NamedUserB:handle_call/3", "NamedTargetB"] in r["sync_dep"]
    refute ["NamedUserA:handle_call/3", "NamedTargetB"] in r["reaches_sync_dep"]
    refute ["NamedUserB:handle_call/3", "NamedTargetA"] in r["reaches_sync_dep"]
    refute Enum.any?(r["sync_dep"], &match?(["NamedCall:" <> _, _], &1))

    # Anchored at the call into the wrapper.
    assert Enum.any?(
             r["sync_site"],
             &match?(
               ["NamedUserB:handle_call/3", "NamedTargetB", "NamedUserB:handle_call/3#" <> _],
               &1
             )
           )
  end

  test "a gen_statem's data carries its pids from state to state", ctx do
    r = solve(ctx, ~w(sync_dep statem_data_pts))
    assert ["Machine:idle/3", "Back"] in r["sync_dep"]
  end

  test "exit signals, monitors and links go to the processes they name", ctx do
    r = solve(ctx, ~w(signal_target watched_process exit_to_own_process))
    signals = for [_, f, signal, p] <- unsited(r["signal_target"]), do: {f, signal, p}

    # The helper Keeper started and keeps in its state.
    assert {"Keeper:handle_cast/2", "exit", "spawn Keeper:init/1"} in signals
    assert Enum.any?(r["exit_to_own_process"], &match?([_, "Keeper:handle_cast/2"], &1))
    # The watcher it monitors.
    assert Enum.any?(
             unsited(r["watched_process"]),
             &match?(["spawn Keeper:init/1", "monitor"], &1)
           )

    # A peer handed in a cast and killed through a helper: the signal is
    # the helper's, the target the caller's.
    assert {"Keeper:stop/1", "exit", "start KeeperClient:drop/0"} in signals
  end

  test "a call to self() or to its own name from a callback is a self-call",
       ctx do
    r = solve(ctx, ~w(self_call))
    calls = for [f, _site] <- r["self_call"], do: f

    assert Enum.count(calls, &(&1 == "Keeper:handle_call/3")) == 2
  end

  test "a pid a server replies with reaches its caller", ctx do
    r = solve(ctx, ~w(sync_dep process_call))
    # The directory keeps workers under keys it does not know and replies
    # with one; the client calls what it gets.
    assert ["DirectoryClient:ping/1", "Back"] in r["sync_dep"]

    # A read by a key not known does not read a field written under a
    # literal key: the socket's transport is not every dynamic read of it.
    refute Enum.any?(r["process_call"], &match?(["Carrier:" <> _ | _], &1))
  end

  test "a private start of a supervised module is not the supervised child",
       ctx do
    r =
      solve(ctx, ~w(process_call instance supervised_process private_process server_process))

    targets = for ["ConnUser:handle_call/3", _, _, "call", p] <- r["process_call"], do: p
    assert targets == ["start ConnUser:init/1#8"]

    assert ["child ConnSup#0", "ConnSup", "0"] in r["supervised_process"]

    assert ["start ConnUser:init/1#8", "ConnUser:init/1", "ConnUser:init/1#8"] in r[
             "private_process"
           ]

    # Both are Conn's, and both come from the one start in Conn.start_link/1.
    [base] = for ["child ConnSup#0", b] <- r["instance"], do: b
    assert ["start ConnUser:init/1#8", base] in r["instance"]
    assert ["child ConnSup#0", "Conn"] in r["server_process"]
    assert ["start ConnUser:init/1#8", "Conn"] in r["server_process"]
  end

  test "a computed module, apply and a library pid name no process", ctx do
    r = solve(ctx, ~w(call_target send_target))

    for row <- r["call_target"] ++ r["send_target"] do
      refute Enum.any?(row, &String.starts_with?(&1, "Quiet:")), inspect(row)
    end
  end
end
