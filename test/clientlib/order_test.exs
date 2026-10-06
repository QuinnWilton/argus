defmodule Argus.Clientlib.OrderTest do
  @moduledoc """
  clientlib/order.dl's `runs_after`, over the block facts the pipeline
  derives (`site_block`, `block_flow`): the shapes it must order, and
  agreement with `Argus.Cfg.Function.precedes?/3`, the reading of the
  graph the extractors order effects by, from every call and receive to
  every call, receive and branch in the fixture and in a real library
  module: the pipeline emits only the sites such an order takes part in,
  and the check is over the instructions, not over what it emitted.
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  alias Argus.{Cfg, InstrId, Pipeline, Souffle}
  alias Argus.Test.Fixtures.Order

  @moduletag :tmp_dir

  defp priv_dl, do: Path.join(:code.priv_dir(:argus_beam), "dl")

  # Every call and receive is asked about (a branch is never asked of),
  # so the rows are the whole relation.
  defp runs_after(modules, tmp_dir) do
    facts_dir = Path.join(tmp_dir, "facts")
    {:ok, _} = Pipeline.run(modules, facts_dir)

    rules_path = Path.join(tmp_dir, "order.dl")

    File.write!(rules_path, """
    .include "#{Path.join(priv_dl(), "base.dl")}"
    .include "#{Path.join(priv_dl(), "clientlib/order.dl")}"

    .init order = RunsAfter
    order.asked(a) :- site_block(a, "call", _, _).
    order.asked(a) :- site_block(a, "receive", _, _).

    .decl runs_after(before: symbol, after: symbol)
    .output runs_after
    runs_after(a, z) :- order.runs_after(a, z).

    .decl site(id: symbol, kind: symbol)
    .output site
    site(a, k) :- site_block(a, k, _, _).

    // Every instruction of the kinds site_block holds, emitted or not.
    .decl instruction_of(id: symbol, kind: symbol)
    .output instruction_of
    instruction_of(id, "call") :- local_call(id, _, _, _).
    instruction_of(id, "call") :- remote_call(id, _, _, _, _).
    instruction_of(id, "receive") :- recv_start(id, _, _, _).
    instruction_of(id, "branch") :- branch(id, _, _).

    .decl callee(id: symbol, func: symbol)
    .output callee
    callee(id, func) :- remote_call(id, _, "Argus.Test.Fixtures.Order.Steps", func, _).

    .decl receive(id: symbol)
    .output receive
    receive(id) :- site_block(id, "receive", _, _).
    """)

    out = Path.join(tmp_dir, "out")
    File.mkdir_p!(out)
    {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: out)
    results
  end

  describe "the shapes" do
    setup %{tmp_dir: tmp_dir} do
      results = runs_after([Order], tmp_dir)
      name = Map.new(results["callee"], fn [id, func] -> {id, func} end)

      pairs =
        for [a, z] <- results["runs_after"],
            Map.has_key?(name, a) and Map.has_key?(name, z),
            into: MapSet.new(),
            do: {name[a], name[z]}

      %{pairs: pairs, results: results, name: name}
    end

    test "a straight path runs each call after the ones before it", %{pairs: pairs} do
      assert {"first", "second"} in pairs
      assert {"first", "third"} in pairs
      assert {"second", "third"} in pairs
      refute {"second", "first"} in pairs
      refute {"third", "first"} in pairs
    end

    test "two arms of a branch: neither after the other, the join after both", %{pairs: pairs} do
      refute {"left", "right"} in pairs
      refute {"right", "left"} in pairs
      assert {"left", "join"} in pairs
      assert {"right", "join"} in pairs
      refute {"join", "left"} in pairs
    end

    test "a later clause of the function never runs after an earlier one", %{pairs: pairs} do
      refute {"clause_one", "clause_two"} in pairs
      refute {"clause_two", "clause_one"} in pairs
    end

    test "a try's handler does not run after what the try covers", %{pairs: pairs} do
      refute {"covered", "handler"} in pairs
      refute {"handler", "covered"} in pairs
    end

    test "a receive's clause and what follows it run after the receive, not before",
         %{results: results, name: name} do
      [[recv]] = Enum.filter(results["receive"], fn [id] -> id =~ "Order:waits/0#" end)

      after_recv = for [^recv, z] <- results["runs_after"], Map.has_key?(name, z), do: name[z]
      assert Enum.sort(after_recv) == ["after_receive", "in_clause"]

      refute Enum.any?(results["runs_after"], fn [a, z] ->
               z == recv and Map.get(name, a) in ["in_clause", "after_receive"]
             end)
    end
  end

  test "agrees with Cfg.Function.precedes?/3 from every call and receive", %{tmp_dir: tmp_dir} do
    modules = [Order, GenServer, :gen_server]
    results = runs_after(modules, tmp_dir)
    ordered = MapSet.new(results["runs_after"], fn [a, z] -> {a, z} end)
    emitted = MapSet.new(results["site"], fn [id, kind] -> {id, kind} end)
    instructions = MapSet.new(results["instruction_of"], fn [id, kind] -> {id, kind} end)

    # Nothing but those kinds, each row its instruction's kind.
    assert MapSet.subset?(emitted, instructions)

    for module <- modules do
      {:ok, typed} = Pipeline.extract([module], format: :typed)
      cfgs = Cfg.build(typed)

      sites =
        for {id, kind} <- instructions,
            {:ok, %InstrId{} = site} = InstrId.parse(id),
            site.module == inspect(module),
            Map.has_key?(cfgs, InstrId.fa(site)),
            do: {site, kind}

      by_function = Enum.group_by(sites, fn {site, _} -> InstrId.fa(site) end)
      assert by_function != %{}

      for {fa, sites} <- by_function,
          {a, kind} <- sites,
          kind in ["call", "receive"],
          {z, _} <- sites do
        expected = Cfg.Function.precedes?(Map.fetch!(cfgs, fa), a.idx, z.idx)
        actual = MapSet.member?(ordered, {InstrId.format(a), InstrId.format(z)})

        assert actual == expected,
               "#{InstrId.format(a)} -> #{InstrId.format(z)}: runs_after says #{actual}, " <>
                 "precedes? says #{expected}"
      end
    end
  end
end
