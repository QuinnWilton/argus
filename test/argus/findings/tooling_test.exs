defmodule Argus.Findings.ToolingTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Tooling

  doctest Tooling

  defp finding(severity, module, opts \\ []),
    do: Findings.new(severity, "t", "d", [at: Findings.at_module(module)] ++ opts)

  @index Tooling.index([
           ["Mix.Tasks.Seed", "mix", "1000"],
           ["App.Support", "test_support", "1000"]
         ])

  test "a structural basis steps down and says what the module is, keeping the provenance" do
    f = Tooling.retier(finding(:error, "App.Support"), @index)
    assert {f.severity, f.provenance, f.confidence} == {:warning, :structural, nil}
    assert ["tooling: test support compiled into this build: only tests run it"] = f.help
  end

  test "info stays info, and a module no row names is untouched" do
    assert %{severity: :info} = Tooling.retier(finding(:info, "Mix.Tasks.Seed"), @index)

    product = finding(:error, "App.Worker")
    assert Tooling.retier(product, @index) == product
    assert Tooling.retier(Findings.new(:error, "t", "d"), @index).severity == :error
  end

  test "an Erlang module is matched as its rows spell it" do
    index = Tooling.index([[":erts_debug", "test_support", "1000"]])
    assert %{severity: :warning} = Tooling.retier(finding(:error, ":erts_debug"), index)
  end
end
