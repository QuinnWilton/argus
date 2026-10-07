defmodule Argus.Findings.RunTest do
  use ExUnit.Case, async: true

  alias Argus.Findings

  @moduletag :tmp_dir

  @tag :flowlog
  test "an empty selection runs nothing and extracts nothing" do
    assert {:ok, %Findings{findings: [], ran: [], degraded: [], extraction_errors: []}} =
             Findings.run([:fake_module_never_read], analyses: [])
  end

  test "a selection that does not resolve is an error before anything runs" do
    assert {:error, {:unknown_analysis, :nope}} = Findings.run([:lists], analyses: [:nope])
    assert {:error, {:invalid_analyses, "all"}} = Findings.run([:lists], analyses: "all")
  end

  describe "extraction_errors/1" do
    test "reads the rows in order, a module that does not parse keeping its source",
         %{tmp_dir: dir} do
      File.write!(
        Path.join(dir, "extraction_error.facts"),
        "Foo.Bar\tArgus.Extractors.Ets\tboom\n/tmp/x.beam\tpipeline\tunreadable\n"
      )

      assert Findings.extraction_errors(dir) == [
               %{
                 module: Foo.Bar,
                 source: "Foo.Bar",
                 step: "Argus.Extractors.Ets",
                 reason: "boom"
               },
               %{module: nil, source: "/tmp/x.beam", step: "pipeline", reason: "unreadable"}
             ]
    end

    test "a directory without the file is not an extraction's, and raises naming it",
         %{tmp_dir: dir} do
      path = Path.join(dir, "extraction_error.facts")

      assert_raise Argus.MissingRelationError, ~r/extraction_error relation's file/, fn ->
        Findings.extraction_errors(dir)
      end

      error = catch_error(Findings.extraction_errors(dir))
      assert %Argus.MissingRelationError{relation: "extraction_error", path: ^path} = error
    end
  end

  describe "the batch pipeline's options" do
    test "each raises, naming what replaces it" do
      for {option, value, says} <- [
            {:backend, :batch, "one backend"},
            {:facts_dir, "/tmp/facts", "run_rules"},
            {:cache, "/tmp/store", "store:"},
            {:solve_cache, "/tmp/solves", "store:"},
            {:extractors, [Argus.Extractors.OTP], "Argus.Pipeline.extract/2"},
            {:relations, :all, "extract_facts"}
          ] do
        for call <- [
              fn -> Findings.run([:lists], [{option, value}]) end,
              fn -> Argus.analyze([:lists], :effects, [{option, value}]) end,
              fn -> Argus.Analysis.extract_facts([:lists], [:effects], [{option, value}]) end
            ] do
          error = assert_raise ArgumentError, call
          assert error.message =~ inspect(option)
          assert error.message =~ says
        end
      end
    end
  end
end
