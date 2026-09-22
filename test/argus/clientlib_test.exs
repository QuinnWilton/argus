defmodule Argus.ClientlibTest do
  @moduledoc """
  The vocabulary under `priv/dl/clientlib/`, run over hand-written
  facts: each predicate says what its name says.

  The program includes the real `imports.dl` and `otp.dl`, so every
  schema relation is declared as the analyses see it; the facts not
  named here are empty.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Argus.Schema
  alias Argus.Souffle

  @program ~S"""
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
  out("sibling", a, b) :- sibling(_, a, b).
  out("sup_op", f, op) :- sup_management_call(_, f, _, op, _).
  out("deferral", m, k) :- deferral_path(m, k).
  out("init_dep", m, to) :- init_dep(m, to, "call", _).
  out("handler_dep", m, to) :- handler_dep(m, "handle_call", to, "call", _).
  out("module_dep", m, to) :- module_sync_dep(m, to, _).
  """

  # M is a GenServer whose init and handle_call wait on W; W is a
  # GenServer; S a gen_statem; T a GenServer whose handle_info is total.
  @facts %{
    "function_def" => [
      ~w(M:init/1 M init 1 1),
      ~w(M:f/0 M f 0 1),
      ~w(M:g/0 M g 0 1),
      ~w(M:handle_info/2 M handle_info 2 1),
      ~w(M:handle_call/3 M handle_call 3 1),
      ~w(M:helper/0 M helper 0 0),
      ~w(W:handle_call/3 W handle_call 3 1),
      ~w(S:handle_event/4 S handle_event 4 1),
      ~w(T:handle_info/2 T handle_info 2 1)
    ],
    "implements_behaviour" => [
      ~w(M GenServer),
      ~w(W GenServer),
      ~w(S GenStateMachine),
      ~w(T GenServer)
    ],
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
    "callback_total" => [~w(T:handle_info/2 handle_info)],
    "supervisor_child" => [~w(Sup 0 M permanent worker), ~w(Sup 1 W permanent worker)],
    "sup_call" => [~w(s1 M:f/0 Supervisor start_child Sup), ~w(s2 M:f/0 GenServer stop W)],
    "mailbox_writer" => [~w(w1 M:g/0 timer)],
    # init and handle_call both go through helper, which calls W.
    "sync_call" => [~w(M:helper/0 W)],
    "remote_call" => [~w(c1 M:init/1 M helper 0), ~w(c2 M:handle_call/3 M helper 0)],
    "local_call" => [~w(c1 M:init/1 M:helper/0 0), ~w(c2 M:handle_call/3 M:helper/0 0)]
  }

  setup %{tmp_dir: dir} do
    unless Souffle.available?(), do: flunk("souffle not installed")

    facts = Path.join(dir, "facts")
    File.mkdir_p!(facts)

    # Every input relation needs a facts file, empty or not.
    for name <- Schema.names() ++ [:call_edge, :call_site, :unconditional_call_edge, :call_tag] do
      File.write!(Path.join(facts, "#{name}.facts"), "")
    end

    # The call graph is stage 0's; here it is the local calls.
    call_edges = for [_, caller, callee, _] <- @facts["local_call"], do: [caller, callee]

    for {rel, rows} <- Map.put(@facts, "call_edge", call_edges) do
      File.write!(
        Path.join(facts, rel <> ".facts"),
        Enum.map_join(rows, "", &(Enum.join(&1, "\t") <> "\n"))
      )
    end

    lib = Path.join(:code.priv_dir(:panoptes), "dl/clientlib")
    program = Path.join(dir, "vocabulary.dl")

    File.write!(
      program,
      ~s(.include "#{lib}/imports.dl"\n.include "#{lib}/otp.dl"\n) <> @program
    )

    {:ok, %{"out" => rows}} = Souffle.run(facts, program)

    out =
      rows
      |> Enum.group_by(&hd/1, fn [_, a, b] -> {a, b} end)
      |> Map.new(fn {k, v} -> {k, Enum.sort(v)} end)

    {:ok, out: out}
  end

  test "closures: every function owns itself; a closure's chain ends at a function", %{out: out} do
    assert {"M:f/0-c2", "M:f/0"} in out["enclosing"]
    assert {"M:f/0-c2", "M:f/0-c1"} in out["enclosing"]
    assert {"M:g/0", "M:g/0"} in out["enclosing"]
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
    assert out["process"] == [{"M", ""}, {"S", ""}, {"T", ""}, {"W", ""}]
    assert out["statem"] == [{"S", ""}]
    # M and T define handle_info/2; S is a statem with handle_event/4.
    assert out["mailbox"] == [{"M", ""}, {"S", ""}, {"T", ""}]
    # T's handle_info has a catch-all; M's does not.
    assert out["partial"] == [{"M", "M:handle_info/2"}]
  end

  test "supervision: siblings both ways, management calls without GenServer.stop", %{out: out} do
    assert out["sibling"] == [{"M", "W"}, {"W", "M"}]
    assert out["sup_op"] == [{"M:f/0", "start_child"}]
  end

  test "startup and entries: deferral paths and what each entry waits on", %{out: out} do
    assert out["deferral"] == [{"M", "timer"}]
    assert out["init_dep"] == [{"M", "W"}]
    assert out["handler_dep"] == [{"M", "W"}]
    assert out["module_dep"] == [{"M", "W"}]
  end
end
