defmodule Argus.Extractors.DependenceTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.CallSites
  alias Argus.Extractors.Dependence
  alias Argus.Extractors.ETS
  alias Argus.Extractors.ProcessRegistry
  alias Argus.Findings
  alias Argus.InstrId
  alias Argus.Pipeline.Disassemble
  alias Argus.Test.Fixtures.CheckThenAct, as: C

  @modules [
    C.WhereisThenStart,
    C.StartHelper,
    C.LookupHelper,
    C.DispatchHelper,
    C.PublicCache,
    :padl2010_ets_inc
  ]

  setup_all do
    {:ok, facts} = Argus.Pipeline.extract(@modules, extractors: [Dependence])
    %{facts: facts}
  end

  defp in_func(rows, pos, fragment),
    do: Enum.filter(rows, &String.contains?(Enum.at(&1, pos), fragment))

  defp site_deps(facts, fragment) do
    for [site, _func, kind, source] <- in_func(facts.site_depends, 0, fragment),
        do: {site, kind, source}
  end

  # The instruction IDs of the calls to `mfa` in functions matching `fragment`.
  defp sites_at(fragment, mfa) do
    for mod <- @modules,
        {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(mod))),
        site <- CallSites.index(data.module, data.functions),
        site.mfa == mfa,
        id = InstrId.mint(site.func_id, site.idx),
        String.contains?(id, fragment),
        do: id
  end

  # The MFA of the remote call at an instruction ID.
  defp site_mfa(id) do
    {:ok, %InstrId{module: m, func: f, arity: a, idx: idx}} = InstrId.parse(id)
    mod = Findings.module_atom(m)
    {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(mod)))

    Enum.find_value(CallSites.index(data.module, data.functions), fn site ->
      if site.func_id == InstrId.func_id(m, f, a) and site.idx == idx, do: site.mfa
    end)
  end

  describe "site_depends" do
    test "a start the lookup's test decides depends on the lookup", %{facts: facts} do
      [whereis] = sites_at("WhereisThenStart:ensure", {Process, :whereis, 1})
      [start] = sites_at("WhereisThenStart:ensure", {GenServer, :start_link, 3})

      assert {start, "site", whereis} in site_deps(facts, "WhereisThenStart:ensure")
    end

    test "a clause's act depends on the parameter the clauses dispatch on", %{facts: facts} do
      [start] = sites_at("DispatchHelper:do_ensure", {GenServer, :start_link, 3})
      assert {start, "param", "0"} in site_deps(facts, "DispatchHelper:do_ensure")
    end
  end

  describe "call summaries" do
    test "a call the lookup decides: call_decided", %{facts: facts} do
      [whereis] = sites_at("StartHelper:ensure", {Process, :whereis, 1})

      assert [_, "Argus.Test.Fixtures.CheckThenAct.StartHelper:start/1", "site", ^whereis] =
               Enum.find(facts.call_decided, &match?([_, _, "site", ^whereis], &1))
    end

    test "an argument made from the lookup: call_arg_depends", %{facts: facts} do
      [whereis] = sites_at("DispatchHelper:ensure", {Process, :whereis, 1})

      assert [
               "Argus.Test.Fixtures.CheckThenAct.DispatchHelper:ensure/1",
               "Argus.Test.Fixtures.CheckThenAct.DispatchHelper:do_ensure/2",
               "0",
               "site",
               whereis
             ] in facts.call_arg_depends
    end

    test "a helper returning its lookup: returns_depends", %{facts: facts} do
      [whereis] = sites_at("LookupHelper:lookup", {Process, :whereis, 1})

      assert ["Argus.Test.Fixtures.CheckThenAct.LookupHelper:lookup/1", "site", whereis] in facts.returns_depends
    end

    test "a closure's captured variable is its environment parameter", %{facts: facts} do
      [new] = sites_at(":padl2010_ets_inc:run", {:ets, :new, 2})

      assert Enum.any?(facts.call_arg_depends, fn
               [":padl2010_ets_inc:run/0", callee, _slot, "site", ^new] ->
                 callee =~ "-run/0-fun-0-"

               _ ->
                 false
             end)
    end
  end

  describe "emission" do
    test "no row names a runtime callee or a runtime call's result", %{facts: facts} do
      runtime = ~w(:erlang: Kernel: Enum: :lists: RuntimeError: Process:info)

      for relation <- [:call_decided, :call_arg_depends, :returns_depends],
          row <- facts[relation] do
        callee_and_sources = tl(row)
        refute Enum.any?(callee_and_sources, &String.starts_with?(&1, runtime)), inspect(row)
      end
    end

    test "rows are per function: two calls to one callee share them" do
      {:ok, a} = Argus.Pipeline.extract([C.StartHelper], extractors: [Dependence])
      assert a.call_decided == Enum.uniq(a.call_decided)
      assert a.call_arg_depends == Enum.uniq(a.call_arg_depends)
    end
  end

  describe "site?/1" do
    # Every site a family extractor emits must be one Dependence follows,
    # or its race rule never sees what decides it.
    test "covers every lookup, claim, release and table operation the families emit" do
      modules =
        [
          C.WhereisThenStart,
          C.LookupThenStartChild,
          C.WhereisThenRegister,
          C.UnregisterIfPresent,
          C.RegisterIfUnlisted,
          C.HandlesAlreadyRegistered,
          C.PublicCache
        ]

      {:ok, facts} =
        Argus.Pipeline.extract(modules, extractors: [ProcessRegistry, ETS])

      ids =
        for relation <- [:name_lookup, :creating_op, :name_release, :ets_op],
            [id | _] <- Map.get(facts, relation, []),
            do: id

      assert length(ids) > 10

      for id <- Enum.uniq(ids) do
        assert Dependence.site?(site_mfa(id)), "#{id} is not a Dependence site"
      end
    end
  end
end
