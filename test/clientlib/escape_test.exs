defmodule Argus.Clientlib.EscapeTest do
  @moduledoc """
  clientlib/escape.dl's `Escape`: whether a raise leaves the function a
  rule reasons about, asked of the raising site, the calls on a path
  down to it and the calls into the function, never of a handler
  elsewhere in the function.
  """
  use ExUnit.Case, async: true

  alias Argus.{Pipeline, Souffle}
  alias Argus.Test.Fixtures.Escape

  @modules [
    Escape.Bare,
    Escape.Rescued,
    Escape.RescuesEveryError,
    Escape.UnrelatedRescue,
    Escape.WrongClass,
    Escape.CatchesExit,
    Escape.Reraises,
    Escape.HelperRescue,
    Escape.HelperUnguarded,
    Escape.CallerRescues,
    Escape.OneCallerUnguarded,
    Escape.ClosureInTry,
    Escape.ClosureOutsideTry,
    Escape.WrapperRescues,
    Escape.WrapperReraises,
    Escape.ErpcCaught,
    Escape.ErpcCaughtAsExit
  ]

  defp priv_dl, do: Path.join(:code.priv_dir(:argus_beam), "dl")

  setup_all do
    unless Souffle.available?(), do: flunk("souffle not installed")

    tmp_dir = Path.join(System.tmp_dir!(), "escape_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    facts_dir = Path.join(tmp_dir, "facts")

    extractors =
      Enum.uniq(Argus.Analyses.Failure.extractors() ++ Argus.Analyses.Races.extractors())

    {:ok, _} = Pipeline.run(@modules, facts_dir, extractors: extractors)
    # imports.dl reads the staged call graph and processes.
    :ok = Argus.Analysis.derive_stage0(facts_dir)
    :ok = Argus.Analysis.derive_points_to(facts_dir)
    rules_path = Path.join(tmp_dir, "escape.dl")

    File.write!(rules_path, """
    .include "#{Path.join(priv_dl(), "clientlib/imports.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/otp.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/escape.dl")}"

    .init escape = Escape

    .decl raise_site(site: symbol, func: symbol, raise: symbol)
    raise_site(s, g, "badarg") :- remote_call(s, g, ":ets", "update_counter", 3).
    raise_site(s, g, "erpc") :- remote_call(s, g, ":erpc", "call", 4).

    escape.asked(s, g, f, r) :-
      raise_site(s, g, r),
      function_def(f, m, "root", _, _),
      enclosing_function(g, o),
      function_def(o, m, _, _, _).

    .decl escapes(mod: symbol, raise: symbol)
    .output escapes
    escapes(m, r) :- escape.escapes(_, f, r), function_def(f, m, _, _, _).

    .decl asked(mod: symbol, raise: symbol)
    .output asked
    asked(m, r) :- escape.asked(_, _, f, r), function_def(f, m, _, _, _).
    """)

    out = Path.join(tmp_dir, "out")
    File.mkdir_p!(out)
    {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: out)

    short = fn m -> m |> String.split(".") |> List.last() end
    rows = fn name -> MapSet.new(results[name], fn [m, r] -> {short.(m), r} end) end
    %{escapes: rows.("escapes"), asked: rows.("asked")}
  end

  defp escapes?(ctx, mod, raise \\ "badarg") do
    assert {mod, raise} in ctx.asked, "#{mod} asks nothing about #{raise}"
    {mod, raise} in ctx.escapes
  end

  describe "a handler around the raising call" do
    test "no handler: the raise escapes", ctx do
      assert escapes?(ctx, "Bare")
    end

    test "a rescue of the raise takes it", ctx do
      refute escapes?(ctx, "Rescued")
    end

    test "a rescue of every error takes it", ctx do
      refute escapes?(ctx, "RescuesEveryError")
    end

    test "a rescue around other code in the function takes nothing of it", ctx do
      assert escapes?(ctx, "UnrelatedRescue")
    end

    test "a rescue of another exception takes nothing of it", ctx do
      assert escapes?(ctx, "WrongClass")
    end

    test "a catch of another class takes nothing of it", ctx do
      assert escapes?(ctx, "CatchesExit")
    end

    test "a rescue that re-raises takes nothing of it", ctx do
      assert escapes?(ctx, "Reraises")
    end
  end

  describe "a handler on the path down" do
    test "a rescue around the call into the helper takes it", ctx do
      refute escapes?(ctx, "HelperRescue")
    end

    test "a rescue elsewhere, the helper called outside it", ctx do
      assert escapes?(ctx, "HelperUnguarded")
    end

    test "a rescue around the call a closure is handed to takes it", ctx do
      refute escapes?(ctx, "ClosureInTry")
    end

    test "a closure handed to a call outside the rescue", ctx do
      assert escapes?(ctx, "ClosureOutsideTry")
    end

    test "a closure handed to a function that runs it under a rescue", ctx do
      refute escapes?(ctx, "WrapperRescues")
    end

    test "a closure handed to a function whose rescue raises again", ctx do
      assert escapes?(ctx, "WrapperReraises")
    end
  end

  describe "the callers" do
    test "every call to a private function inside a rescue takes it", ctx do
      refute escapes?(ctx, "CallerRescues")
    end

    test "one unguarded caller keeps it escaping", ctx do
      assert escapes?(ctx, "OneCallerUnguarded")
    end
  end

  describe "other raises" do
    test "a catch of the :erpc error takes an erpc raise", ctx do
      refute escapes?(ctx, "ErpcCaught", "erpc")
    end

    test "a catch of exits takes nothing of an erpc raise", ctx do
      assert escapes?(ctx, "ErpcCaughtAsExit", "erpc")
    end
  end
end
