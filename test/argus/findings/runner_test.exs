defmodule Argus.Findings.RunnerTest do
  use ExUnit.Case, async: true

  alias Argus.Findings
  alias Argus.Findings.Runner

  @moduletag :tmp_dir

  test "an empty selection runs nothing and extracts nothing" do
    assert {:ok, %Findings{findings: [], ran: [], degraded: [], extraction_errors: []}} =
             Runner.run([:fake_module_never_read], analyses: [])
  end

  test "a selection that does not resolve is an error before anything runs" do
    assert {:error, {:unknown_analysis, :nope}} = Runner.run([:lists], analyses: [:nope])
    assert {:error, {:invalid_analyses, "all"}} = Runner.run([:lists], analyses: "all")
  end

  describe "extraction_errors/1" do
    test "reads the rows in order, a module that does not parse keeping its source",
         %{tmp_dir: dir} do
      File.write!(
        Path.join(dir, "extraction_error.facts"),
        "Foo.Bar\tArgus.Extractors.Ets\tboom\n/tmp/x.beam\tpipeline\tunreadable\n"
      )

      assert Runner.extraction_errors(dir) == [
               %{
                 module: Foo.Bar,
                 source: "Foo.Bar",
                 step: "Argus.Extractors.Ets",
                 reason: "boom"
               },
               %{module: nil, source: "/tmp/x.beam", step: "pipeline", reason: "unreadable"}
             ]

      assert Findings.extraction_errors(dir) == Runner.extraction_errors(dir)
    end

    test "a directory without the file has none", %{tmp_dir: dir} do
      assert Runner.extraction_errors(dir) == []
    end
  end
end
