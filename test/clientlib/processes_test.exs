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
          Argus.Extractors.PidFlow
        ]
      )

    :ok = Analysis.derive_stage0(facts_dir)

    rules = """
    .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/sends.dl")}"
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

    assert ["Worker:ping/1", "0", "server Worker:start_link/1"] in unsited(r["param_pts"])
    assert ["Owner:relay/1", "0", "server Worker:start_link/1"] in unsited(r["param_pts"])
    assert ["Worker:notify/1", "cast", "server Worker:start_link/1"] in unsited(r["call_target"])

    assert ["Owner:across_a_call/0", "call", "server Owner:across_a_call/0"] in unsited(
             r["call_target"]
           )
  end

  test "resolved calls become dependencies on the server's module", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep async_dep))

    assert ["Owner:direct/0", "Worker"] in r["sync_dep"]
    assert ["Worker:ping/1", "Worker"] in r["sync_dep"]
    assert ["Worker:notify/1", "Worker"] in r["async_dep"]
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
    assert ["Front:handle_call/3", "call", "server Back:start_link/0"] in unsited(
             r["call_target"]
           )

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

  test "a computed module, apply and a library pid name no process", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_target send_target))

    for row <- r["call_target"] ++ r["send_target"] do
      refute Enum.any?(row, &String.starts_with?(&1, "Quiet:")), inspect(row)
    end
  end
end
