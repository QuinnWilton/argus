defmodule Argus.Findings.BuildTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Build

  defmodule CustomEvidence do
    @moduledoc false
    alias Argus.Findings

    def name, do: :custom_evidence

    def output_relations do
      [
        %{name: :finding, fields: [{:mod, :symbol, "module"}], doc: "a finding"},
        %{
          name: :witness,
          fields: [{:mod, :symbol, "module"}, {:site, :symbol, "site"}],
          evidence: %{of: :finding, on: [:mod]},
          doc: "its witnesses"
        }
      ]
    end

    def finding(:finding, ["boom"]), do: raise("no boom")
    def finding(:finding, [mod]), do: Findings.new(:info, "t", "d", at: Findings.at_module(mod))

    def evidence(:witness, [_mod, "boom"]), do: raise("no boom")
    def evidence(:witness, [_mod, site]), do: Findings.related("witness", Findings.at_instr(site))
  end

  test "a raising row is returned as a failure beside the findings" do
    results = %{
      "finding" => [["Foo"], ["boom"]],
      "witness" => [["Foo", "Foo:f/0#1"], ["Foo", "boom"]]
    }

    {findings, failures} = Build.build(CustomEvidence, results)

    assert length(findings) == 2

    assert Enum.map(failures, &{&1.relation, &1.row}) == [
             {:finding, ["boom"]},
             {:witness, ["Foo", "boom"]}
           ]

    assert Enum.all?(failures, &match?(%RuntimeError{message: "no boom"}, &1.exception))
    assert Findings.build(CustomEvidence, results) == findings
  end

  test "evidence frames join their finding, and every finding carries its analysis" do
    results = %{"finding" => [["Foo"]], "witness" => [["Foo", "Foo:f/0#1"], ["Bar", "Bar:g/0#2"]]}

    assert {[finding], []} = Build.build(CustomEvidence, results)
    assert finding.analysis == :custom_evidence and finding.concern == :custom_evidence
    assert [%{label: "witness", mfa: {Foo, :f, 0}}] = finding.related
  end

  test "relations the analysis does not declare are ignored" do
    assert {[], []} = Build.build(CustomEvidence, %{"call_reachable" => [["x", "y"]]})
  end
end
