defmodule Argus.ClientlibTest do
  @moduledoc """
  The vocabulary in `priv/dl/clientlib/{closures,receive,exceptions,
  effects,process}.dl`, run over hand-written facts: each predicate says
  what its name says.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Argus.Souffle

  # Only the facts these predicates read, declared the way layer2.dl
  # declares them.
  @program ~S"""
  .decl function_def(func: symbol, mod: symbol, name: symbol, arity: number, exported: number)
  .decl implements_behaviour(mod: symbol, behaviour: symbol)
  .decl closure_def(func: symbol, closure: symbol)
  .decl recv_start(id: symbol, caller: symbol, blocking: number, fail: symbol)
  .decl recv_pattern(id: symbol, func: symbol, message: symbol)
  .decl catch_total(id: symbol, func: symbol, class: symbol)
  .decl callback_total(func: symbol, callback: symbol)
  .input function_def
  .input implements_behaviour
  .input closure_def
  .input recv_start
  .input recv_pattern
  .input catch_total
  .input callback_total

  .decl closure_count(func: symbol, n: number)
  closure_count(func, n) :- closure_def(func, _), n = count : { closure_def(func, _) }.

  .decl behaves_as(mod: symbol, canonical: symbol)
  behaves_as(mod, b) :- implements_behaviour(mod, b).

  .include "closures.dl"
  .include "receive.dl"
  .include "exceptions.dl"
  .include "process.dl"

  .decl out(kind: symbol, a: symbol, b: symbol)
  .output out
  out("enclosing", f, o) :- enclosing_function(f, o).
  out("sole", f, c) :- sole_closure(f, c).
  out("blocking", f, "") :- blocking_receive(f).
  out("timed", f, "") :- timed_receive(f).
  out("takes", m, msg) :- receives_message(m, msg).
  out("catches", f, c) :- catches_class(f, c).
  out("site", id, c) :- site_catches_class(id, _, c).
  out("process", m, "") :- process_module(m).
  out("statem", m, "") :- statem_process(m).
  out("mailbox", m, "") :- mailbox_handler(m).
  out("partial", m, f) :- partial_handle_info(m, f).
  """

  @facts %{
    "function_def" => [
      ~w(M:f/0 M f 0 1),
      ~w(M:g/0 M g 0 1),
      ~w(M:handle_info/2 M handle_info 2 1),
      ~w(S:handle_event/4 S handle_event 4 1),
      ~w(T:handle_info/2 T handle_info 2 1)
    ],
    "implements_behaviour" => [~w(M GenServer), ~w(S GenStateMachine)],
    # f builds one closure, which builds another; g builds two.
    "closure_def" => [
      ~w(M:f/0 M:f/0-c1),
      ~w(M:f/0-c1 M:f/0-c2),
      ~w(M:g/0 M:g/0-c1),
      ~w(M:g/0 M:g/0-c2)
    ],
    "recv_start" => [~w(r1 M:f/0 1 0), ~w(r2 M:g/0 0 0)],
    "recv_pattern" => [~w(r1 M:f/0 :tick), ~w(r2 M:g/0 any)],
    "catch_total" => [~w(t1 M:f/0 exit), ~w(t2 M:g/0 *)],
    "callback_total" => [~w(T:handle_info/2 handle_info)]
  }

  setup %{tmp_dir: dir} do
    unless Souffle.available?(), do: flunk("souffle not installed")

    facts = Path.join(dir, "facts")
    File.mkdir_p!(facts)

    for {rel, rows} <- @facts do
      File.write!(
        Path.join(facts, rel <> ".facts"),
        Enum.map_join(rows, "", &(Enum.join(&1, "\t") <> "\n"))
      )
    end

    lib = Path.join(:code.priv_dir(:panoptes), "dl/clientlib")

    for f <- ~w(closures.dl receive.dl exceptions.dl process.dl),
        do: File.cp!(Path.join(lib, f), Path.join(dir, f))

    program = Path.join(dir, "vocabulary.dl")
    File.write!(program, @program)

    {:ok, %{"out" => rows}} = Souffle.run(facts, program)

    out =
      rows
      |> Enum.group_by(&hd/1, fn [_, a, b] -> {a, b} end)
      |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)

    {:ok, out: out}
  end

  test "closures: every function owns itself; a closure's chain ends at a function", %{out: out} do
    assert out["enclosing"] == [
             {"M:f/0", "M:f/0"},
             {"M:f/0-c1", "M:f/0"},
             {"M:f/0-c2", "M:f/0"},
             {"M:f/0-c2", "M:f/0-c1"},
             {"M:g/0", "M:g/0"},
             {"M:g/0-c1", "M:g/0"},
             {"M:g/0-c2", "M:g/0"},
             {"M:handle_info/2", "M:handle_info/2"},
             {"S:handle_event/4", "S:handle_event/4"},
             {"T:handle_info/2", "T:handle_info/2"}
           ]

    # g builds two, so neither is its sole closure.
    assert out["sole"] == [{"M:f/0", "M:f/0-c1"}, {"M:f/0-c1", "M:f/0-c2"}]
  end

  test "receives: the blocking column and the clause patterns", %{out: out} do
    assert out["blocking"] == [{"M:f/0", ""}]
    assert out["timed"] == [{"M:g/0", ""}]
    assert out["takes"] == [{"M", ":tick"}, {"M", "any"}]
  end

  test "exceptions: a star handler catches every class", %{out: out} do
    assert out["catches"] == [
             {"M:f/0", "exit"},
             {"M:g/0", "error"},
             {"M:g/0", "exit"},
             {"M:g/0", "throw"}
           ]

    assert out["site"] == [{"t1", "exit"}, {"t2", "error"}, {"t2", "exit"}, {"t2", "throw"}]
  end

  test "process: behaviour modules, statems, mailbox handlers, partial handle_info", %{out: out} do
    assert out["process"] == [{"M", ""}, {"S", ""}]
    assert out["statem"] == [{"S", ""}]
    # M and T define handle_info/2; S is a statem with handle_event/4.
    assert out["mailbox"] == [{"M", ""}, {"S", ""}, {"T", ""}]
    # T's handle_info has a catch-all; M's does not.
    assert out["partial"] == [{"M", "M:handle_info/2"}]
  end
end
