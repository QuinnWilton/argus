defmodule Argus.Clientlib.ProcessesTest do
  use ExUnit.Case, async: true

  alias Argus.{Analysis, Pipeline, Souffle}
  alias Argus.Test.Fixtures.PidFlow

  @moduletag :tmp_dir

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
    PidFlow.Quiet
  ]

  defp priv_dl, do: Path.join(:code.priv_dir(:panoptes), "dl")

  defp solve(tmp_dir, outputs) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    facts_dir = Path.join(tmp_dir, "facts")

    {:ok, _} =
      Pipeline.run(@modules, facts_dir,
        extractors: [
          Argus.Extractors.OTP,
          Argus.Extractors.ApiCalls,
          Argus.Extractors.CallbackTag,
          Argus.Extractors.ProcessRegistry,
          Argus.Extractors.Supervision,
          Argus.Extractors.GenStatem,
          Argus.Extractors.PidFlow
        ]
      )

    :ok = Analysis.derive_stage0(facts_dir)

    rules = """
    .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/process_statem.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/sends.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/signals.dl")}"
    #{Enum.map_join(outputs, "\n", &".output #{&1}")}
    """

    rules_path = Path.join(tmp_dir, "processes.dl")
    File.write!(rules_path, rules)
    {:ok, results} = Souffle.run(facts_dir, rules_path)

    Map.new(results, fn {relation, rows} ->
      {relation, Enum.map(rows, fn row -> Enum.map(row, &short/1) end)}
    end)
  end

  defp short(s), do: String.replace(s, "Argus.Test.Fixtures.PidFlow.", "")

  # A process id with its site dropped: "server Worker:start_link/1#6" is
  # "server Worker:start_link/1".
  defp unsite(id), do: String.replace(id, ~r/#\d+$/, "")

  defp unsited(rows), do: Enum.map(rows, fn row -> Enum.map(row, &unsite/1) end)

  test "a pid follows a wrapper's result and two parameters to a cast", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(returns_pts param_pts call_target))

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

  test "resolved calls become dependencies on the server's module", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep async_dep))

    assert ["Owner:direct/0", "Worker"] in r["sync_dep"]
    assert ["Owner:run/0", "Worker"] in r["sync_dep"]
    assert ["Owner:run/0", "Worker"] in r["async_dep"]
  end

  test "a helper's parameter is each caller's pid, not all of them", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep process_call sync_site))
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

  test "a dependency carries the timeout of the call that makes it", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep_timeout))
    timeouts = for ["Timed:handle_call/3", m, ms] <- r["sync_dep_timeout"], do: {m, ms}

    assert {"TargetA", "-1"} in timeouts
    refute {"TargetA", "5000"} in timeouts
  end

  test "self() and a server's state carry a peer's pid", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(param_pts sync_dep))
    params = unsited(r["param_pts"])

    # A starts B with self(): B's init/1, and so B's state, holds A.
    assert ["CycleB:init/1", "0", "server CycleA:start_link/1"] in params
    assert ["CycleB:handle_call/3", "2", "server CycleA:start_link/1"] in params
    # A keeps B's pid, returned from init/1 in {:ok, pid}, as its state.
    assert ["CycleA:handle_call/3", "2", "server CycleB:start_link/1"] in params
    assert ["CycleA:handle_call/3", "CycleB"] in r["sync_dep"]
    assert ["CycleB:handle_call/3", "CycleA"] in r["sync_dep"]
  end

  test "each pid in a state map stays under its key", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_target sync_dep))

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
       %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(send_target))
    sends = for [_, "Relay:handle_info/2", m, p] <- r["send_target"], do: {m, unsite(p)}

    assert {":event", "spawn Subscriber:go/0"} in sends
    assert {":flush", "spawn Relay:init/1"} in sends
    refute {":event", "spawn Relay:init/1"} in sends
  end

  test "a registered name and a captured pid route sends", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(named_pid send_target))

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
       %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_target))
    assert ["Owner:dynamic/0", "call", "server Owner:dynamic/0"] in unsited(r["call_target"])
  end

  test "a GenServer a child spec names is a server, so self() in it resolves",
       %{tmp_dir: tmp_dir} do
    # Kid starts through a helper with a computed module: no start call in
    # the program names it, only Tree's child spec.
    r = solve(tmp_dir, ~w(self_pid process_start))
    refute Enum.any?(r["process_start"], &(Enum.at(&1, 4) == "Kid"))
    assert ["Kid:init/1", "child Tree#0"] in r["self_pid"]
  end

  test "a pid in a cast's message reaches the handler and the server's state",
       %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(param_pts call_target))
    params = unsited(r["param_pts"])

    assert ["Hub:subscribe/1", "0", "server Listener:start_link/1"] in params
    assert Enum.any?(params, &match?(["Hub:handle_cast/2", "0", "Hub:subscribe/1"], &1))

    assert ["Hub:handle_call/3", "call", "server Listener:start_link/1"] in unsited(
             r["call_target"]
           )
  end

  test "starts beyond start_link are processes", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_site_target send_target process_start))
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

  test "a pid in a function's sixth parameter", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(param_pts))
    assert ["Starts:seven/7", "5", "spawn Starts:wide/0"] in unsited(r["param_pts"])
  end

  test "names live in three registries and a child spec", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(named_pid call_site_target))
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
       %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(named_pid))
    # Names spawns a helper and registers it: ProcessRegistry's
    # module-level guess says Names' own process holds the name.
    assert for([":names_helper", p] <- unsited(r["named_pid"]), do: p) ==
             ["spawn Names:park/0"]
  end

  test "self() in a helper is the process that calls it", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(self_pid send_target))

    assert ["SelfHelper:remind/0", "spawn SelfHelper:start/0"] in unsited(r["self_pid"])

    assert Enum.any?(
             unsited(r["send_target"]),
             &match?([_, "SelfHelper:remind/0", ":reminder", "spawn SelfHelper:start/0"], &1)
           )
  end

  test "a gen_statem's data carries its pids from state to state", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep statem_data_pts))
    assert ["Machine:idle/3", "Back"] in r["sync_dep"]
  end

  test "exit signals, monitors and links go to the processes they name", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(signal_target watched_process exit_to_own_process))
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
       %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(self_call))
    calls = for [f, _site] <- r["self_call"], do: f

    assert Enum.count(calls, &(&1 == "Keeper:handle_call/3")) == 2
  end

  test "a pid a server replies with reaches its caller", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep process_call))
    # The directory keeps workers under keys it does not know and replies
    # with one; the client calls what it gets.
    assert ["DirectoryClient:ping/1", "Back"] in r["sync_dep"]

    # A read by a key not known does not read a field written under a
    # literal key: the socket's transport is not every dynamic read of it.
    refute Enum.any?(r["process_call"], &match?(["Carrier:" <> _ | _], &1))
  end

  test "a private start of a supervised module is not the supervised child",
       %{tmp_dir: tmp_dir} do
    r =
      solve(tmp_dir, ~w(process_call instance supervised_process private_process server_process))

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

  test "a computed module, apply and a library pid name no process", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_target send_target))

    for row <- r["call_target"] ++ r["send_target"] do
      refute Enum.any?(row, &String.starts_with?(&1, "Quiet:")), inspect(row)
    end
  end
end
