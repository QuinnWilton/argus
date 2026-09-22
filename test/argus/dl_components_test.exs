defmodule Argus.DlComponentsTest do
  @moduledoc """
  The reachability components in `priv/dl/clientlib/reach.dl`, run over a
  hand-written call graph: each variant's step is what its name says.

      a -> b -> c -> sink        (b -> c is a closure edge)
      k -> sink
      other -> c                 (`other` lives in module N; the rest in M)
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Argus.Souffle

  @program ~S"""
  .decl call_edge(a: symbol, b: symbol)
  .decl closure_def(a: symbol, b: symbol)
  .decl function_def(func: symbol, mod: symbol, name: symbol, arity: number, exported: number)
  .input call_edge
  .input closure_def
  .input function_def
  .include "reach.dl"

  .init call = CallReach
  .init same = SameProcessReach
  .init closure = ClosureReach
  .init intra = IntraModuleReach
  .init call_set = CallReachSet
  .init forward = ForwardCallReach
  .init forward_intra = ForwardIntraModuleReach
  .init forward_set = ForwardCallReachSet
  .init bounded = ForwardBoundedCallReach

  call.seed(f, "x") :- call_edge(f, "sink").
  same.seed(f, "x") :- call_edge(f, "sink").
  closure.seed(f, "x") :- closure_def(_, f).
  intra.seed("c", "c").
  call_set.seed(f) :- call_edge(f, "sink").
  forward.root("a", "a").
  forward_intra.root("a", "a").
  forward_set.root("a").
  bounded.root("a", "a").
  bounded.limit(1).

  .decl out(kind: symbol, f: symbol)
  .output out
  out("call", f) :- call.reaches(f, "x").
  out("same", f) :- same.reaches(f, "x").
  out("closure", f) :- closure.reaches(f, "x").
  out("intra", f) :- intra.reaches(f, "c").
  out("call_set", f) :- call_set.reaches(f).
  out("forward", f) :- forward.reaches("a", f).
  out("forward_intra", f) :- forward_intra.reaches("a", f).
  out("forward_set", f) :- forward_set.reaches(f).
  out("bounded", f) :- bounded.reaches("a", f, _).
  """

  setup %{tmp_dir: dir} do
    unless Souffle.available?(), do: flunk("souffle not installed")

    facts = Path.join(dir, "facts")
    File.mkdir_p!(facts)
    File.write!(Path.join(facts, "call_edge.facts"), "a\tb\nb\tc\nc\tsink\nk\tsink\nother\tc\n")
    File.write!(Path.join(facts, "closure_def.facts"), "b\tc\n")

    File.write!(
      Path.join(facts, "function_def.facts"),
      Enum.map_join(~w(a b c sink k), "", &"#{&1}\tM\t#{&1}\t0\t1\n") <> "other\tN\tother\t0\t1\n"
    )

    reach = Path.join(:code.priv_dir(:panoptes), "dl/clientlib/reach.dl")
    File.cp!(reach, Path.join(dir, "reach.dl"))
    program = Path.join(dir, "components.dl")
    File.write!(program, @program)

    {:ok, %{"out" => rows}} = Souffle.run(facts, program)

    {:ok,
     out:
       rows
       |> Enum.group_by(&hd/1, &Enum.at(&1, 1))
       |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)}
  end

  test "backward variants differ only in the step they take", %{out: out} do
    # Callers of sink: c and k directly, b and other through c, a through b.
    assert out["call"] == ~w(a b c k other)
    # The closure edge b -> c is not followed, so a and b drop out.
    assert out["same"] == ~w(c k other)
    # Seeded at the closure c; the closure edge is followed back to b.
    assert out["closure"] == ~w(a b c other)
    # `other` reaches c but from another module.
    assert out["intra"] == ~w(a b c)
    assert out["call_set"] == ~w(a b c k other)
  end

  test "forward variants walk from the root", %{out: out} do
    assert out["forward"] == ~w(a b c sink)
    assert out["forward_intra"] == ~w(a b c sink)
    assert out["forward_set"] == ~w(a b c sink)
    # One hop past the root.
    assert out["bounded"] == ~w(a b)
  end
end
