defmodule Argus.Findings.ToolingTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Tooling

  doctest Tooling

  defp finding(severity, module, opts \\ []),
    do: Findings.new(severity, "t", "d", [at: Findings.at_module(module)] ++ opts)

  @index Tooling.index([
           ["Mix.Tasks.Seed", "mix", "1000"],
           ["App.Support", "test_support", "1000"],
           ["App.DevSetup", "prior", "940"]
         ])

  test "a structural basis steps down and says what the module is, keeping the provenance" do
    f = Tooling.retier(finding(:error, "App.Support"), @index)
    assert {f.severity, f.provenance, f.confidence} == {:warning, :structural, nil}
    assert ["tooling: test support compiled into this build: only tests run it"] = f.help
  end

  test "the prior's basis makes the finding heuristic at the prior's probability" do
    f = Tooling.retier(finding(:warning, "App.DevSetup"), @index)
    assert {f.severity, f.provenance, f.confidence} == {:info, :heuristic, 940}
    assert [help] = f.help
    assert help =~ "p=0.94"
  end

  test "a finding another prior moved keeps the lower confidence" do
    moved = Findings.heuristic(finding(:error, "App.DevSetup"), 910, "the value is configured")
    f = Tooling.retier(moved, @index)
    assert {f.severity, f.confidence} == {:info, 910}
    assert length(f.help) == 2
  end

  test "info stays info, and a module no row names is untouched" do
    assert %{severity: :info} = Tooling.retier(finding(:info, "Mix.Tasks.Seed"), @index)

    product = finding(:error, "App.Worker")
    assert Tooling.retier(product, @index) == product
    assert Tooling.retier(Findings.new(:error, "t", "d"), @index).severity == :error
  end

  test "a module the structure names is the structure's, whatever the prior says" do
    index = Tooling.index([["M", "prior", "990"], ["M", "mix", "1000"]])
    assert index == %{"M" => {"mix", 1000}}
  end

  test "a floor the builder sets bounds the step" do
    floored = Map.put(finding(:warning, "App.DevSetup"), :floor, :warning)
    assert %{severity: :warning, provenance: :heuristic} = Tooling.retier(floored, @index)

    erred = Map.put(finding(:error, "Mix.Tasks.Seed"), :floor, :warning)
    assert %{severity: :warning} = Tooling.retier(erred, @index)
  end

  test "an Erlang module is matched as its rows spell it" do
    index = Tooling.index([[":erts_debug", "prior", "960"]])
    assert %{severity: :warning} = Tooling.retier(finding(:error, ":erts_debug"), index)
  end
end
