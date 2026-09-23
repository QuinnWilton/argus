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

  test "a pid follows a wrapper's result and two parameters to a cast", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(returns_pid param_pid call_target))

    assert ["Worker:start_link/1", "server Worker"] in r["returns_pid"]
    assert ["Worker:ping/1", "0", "server Worker"] in r["param_pid"]
    assert ["Owner:relay/1", "0", "server Worker"] in r["param_pid"]
    assert ["Worker:notify/1", "cast", "server Worker"] in r["call_target"]
    assert ["Owner:across_a_call/0", "call", "server Worker"] in r["call_target"]
  end

  test "resolved calls become dependencies on the server's module", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(sync_dep async_dep))

    assert ["Owner:direct/0", "Worker"] in r["sync_dep"]
    assert ["Worker:ping/1", "Worker"] in r["sync_dep"]
    assert ["Worker:notify/1", "Worker"] in r["async_dep"]
  end

  test "self() and a server's state carry a peer's pid", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(param_pid sync_dep))

    # A starts B with self(): B's init/1, and so B's state, holds A.
    assert ["CycleB:init/1", "0", "server CycleA"] in r["param_pid"]
    assert ["CycleB:handle_call/3", "2", "server CycleA"] in r["param_pid"]
    # A keeps B's pid, returned from init/1, as its state.
    assert ["CycleA:handle_call/3", "2", "server CycleB"] in r["param_pid"]
    assert ["CycleA:handle_call/3", "CycleB"] in r["sync_dep"]
    assert ["CycleB:handle_call/3", "CycleA"] in r["sync_dep"]
  end

  test "a registered name and a captured pid route sends", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(named_pid send_target))

    assert [":loops", "spawn Loops:loop/0"] in r["named_pid"]

    assert Enum.any?(
             r["send_target"],
             &match?([_, "Loops:start/0", ":tick", "spawn Loops:loop/0"], &1)
           )

    assert Enum.any?(
             r["send_target"],
             &match?([_, "Loops:-start/0-fun-0-/1", "{:done, …}", "spawn Loops:loop/0"], &1)
           )
  end

  test "a child a supervisor starts on request is a process its caller holds",
       %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_target))
    assert ["Owner:dynamic/0", "call", "server Worker"] in r["call_target"]
  end

  test "a GenServer a child spec names is a server, so self() in it resolves",
       %{tmp_dir: tmp_dir} do
    # Kid starts through a helper with a computed module: no start call in
    # the program names it, only Tree's child spec.
    r = solve(tmp_dir, ~w(self_pid process_start))
    refute Enum.any?(r["process_start"], &match?([_, "server Kid" | _], &1))
    assert ["Kid:init/1", "server Kid"] in r["self_pid"]
  end

  test "a computed module, apply and a library pid name no process", %{tmp_dir: tmp_dir} do
    r = solve(tmp_dir, ~w(call_target send_target))

    for row <- r["call_target"] ++ r["send_target"] do
      refute Enum.any?(row, &String.starts_with?(&1, "Quiet:")), inspect(row)
    end
  end
end
