defmodule Argus.Clientlib.DataflowTest do
  use ExUnit.Case

  alias Argus.Souffle.CLI

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless CLI.available?(), do: flunk("souffle not installed")
  end

  defp clientlib_path(name), do: Path.join(:code.priv_dir(:argus), "dl/clientlib/#{name}")

  describe "ForwardDataflow component" do
    @tag :tmp_dir
    test "propagates facts forward through CFG edges", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      File.mkdir_p!(facts_dir)

      # Hand-crafted linear CFG: inst1 -> inst2 -> inst3
      # gen("inst1", "x0") should reach inst2 and inst3.
      rules = """
      .include "#{clientlib_path("dataflow.dl")}"

      .init fwd = ForwardDataflow

      fwd.cfg_edge_in("inst1", "inst2").
      fwd.cfg_edge_in("inst2", "inst3").

      fwd.gen("inst1", "x0").

      // No kills — x0 should reach all successors.

      .decl fwd_result(fact: symbol, point: symbol)
      .output fwd_result

      fwd_result(fact, point) :- fwd.reaches(fact, point).
      """

      rules_path = Path.join(tmp_dir, "test_forward.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = CLI.run(facts_dir, rules_path)
      assert Map.has_key?(results, "fwd_result")

      fwd = results["fwd_result"]

      # x0 should reach inst2 and inst3.
      assert Enum.any?(fwd, fn [fact, point] -> fact == "x0" and point == "inst2" end)
      assert Enum.any?(fwd, fn [fact, point] -> fact == "x0" and point == "inst3" end)
    end

    @tag :tmp_dir
    test "kill stops propagation", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      File.mkdir_p!(facts_dir)

      # inst1 -> inst2 -> inst3, gen x0 at inst1, kill x0 at inst2.
      rules = """
      .include "#{clientlib_path("dataflow.dl")}"

      .init fwd = ForwardDataflow

      fwd.cfg_edge_in("inst1", "inst2").
      fwd.cfg_edge_in("inst2", "inst3").

      fwd.gen("inst1", "x0").
      fwd.kill("inst2", "x0").

      .decl fwd_result(fact: symbol, point: symbol)
      .output fwd_result

      fwd_result(fact, point) :- fwd.reaches(fact, point).
      """

      rules_path = Path.join(tmp_dir, "test_forward_kill.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = CLI.run(facts_dir, rules_path)

      fwd = results["fwd_result"]

      # x0 should reach inst2 but NOT inst3 (killed at inst2).
      assert Enum.any?(fwd, fn [fact, point] -> fact == "x0" and point == "inst2" end)
      refute Enum.any?(fwd, fn [fact, point] -> fact == "x0" and point == "inst3" end)
    end
  end

  describe "BackwardDataflow component" do
    @tag :tmp_dir
    test "propagates liveness backward through CFG edges", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      File.mkdir_p!(facts_dir)

      # Linear CFG: inst1 -> inst2 -> inst3.
      # x0 is used at inst3. It should be live_in at inst2 and inst1.
      rules = """
      .include "#{clientlib_path("dataflow.dl")}"

      .init bwd = BackwardDataflow

      bwd.cfg_edge_in("inst1", "inst2").
      bwd.cfg_edge_in("inst2", "inst3").

      bwd.used("inst3", "x0").

      // No definitions — x0 is live everywhere backward.

      .decl live_in_result(point: symbol, fact: symbol)
      .output live_in_result

      .decl live_out_result(point: symbol, fact: symbol)
      .output live_out_result

      live_in_result(point, fact) :- bwd.live_in(point, fact).
      live_out_result(point, fact) :- bwd.live_out(point, fact).
      """

      rules_path = Path.join(tmp_dir, "test_backward.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = CLI.run(facts_dir, rules_path)

      live_in = results["live_in_result"]
      live_out = results["live_out_result"]

      # x0 is live-in at inst3 (used there), inst2, and inst1.
      assert Enum.any?(live_in, fn [point, fact] -> point == "inst3" and fact == "x0" end)
      assert Enum.any?(live_in, fn [point, fact] -> point == "inst2" and fact == "x0" end)
      assert Enum.any?(live_in, fn [point, fact] -> point == "inst1" and fact == "x0" end)

      # x0 is live-out at inst1 and inst2 (live-in at their successors).
      assert Enum.any?(live_out, fn [point, fact] -> point == "inst1" and fact == "x0" end)
      assert Enum.any?(live_out, fn [point, fact] -> point == "inst2" and fact == "x0" end)
    end

    @tag :tmp_dir
    test "definition stops backward propagation", %{tmp_dir: tmp_dir} do
      skip_without_souffle()

      facts_dir = Path.join(tmp_dir, "facts")
      File.mkdir_p!(facts_dir)

      # inst1 -> inst2 -> inst3.
      # x0 used at inst3, defined at inst2. Should not be live-in at inst1.
      rules = """
      .include "#{clientlib_path("dataflow.dl")}"

      .init bwd = BackwardDataflow

      bwd.cfg_edge_in("inst1", "inst2").
      bwd.cfg_edge_in("inst2", "inst3").

      bwd.used("inst3", "x0").
      bwd.defined("inst2", "x0").

      .decl live_in_result(point: symbol, fact: symbol)
      .output live_in_result

      live_in_result(point, fact) :- bwd.live_in(point, fact).
      """

      rules_path = Path.join(tmp_dir, "test_backward_def.dl")
      File.write!(rules_path, rules)

      assert {:ok, results} = CLI.run(facts_dir, rules_path)

      live_in = results["live_in_result"]

      # x0 is live-in at inst3 (used) but NOT at inst1 (killed at inst2).
      assert Enum.any?(live_in, fn [point, fact] -> point == "inst3" and fact == "x0" end)
      refute Enum.any?(live_in, fn [point, fact] -> point == "inst1" and fact == "x0" end)
    end
  end
end
