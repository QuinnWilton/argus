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

  # A solver that fails the points-to stage and runs everything else.
  defp failing_points_to!(dir) do
    bin = Path.join(dir, "souffle")

    File.write!(bin, """
    #!/bin/sh
    for arg in "$@"; do last="$arg"; done
    case "$last" in
      *points_to.dl) echo "points-to failed" >&2; exit 3 ;;
    esac
    exec #{System.find_executable("souffle")} "$@"
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  # The stage's failure is a warning as well as the degradation.
  @tag :capture_log
  test "a failed points-to stage degrades only the analyses that read it", %{tmp_dir: dir} do
    assert {:ok, %Findings{ran: ran, degraded: degraded}} =
             Runner.run([:lists],
               analyses: [:startup, :effects],
               souffle_bin: failing_points_to!(dir)
             )

    assert [%{analysis: :effects}] = ran

    assert [%{analysis: :startup, reason: {:points_to, {:souffle_error, 3, _}}, detail: detail}] =
             degraded

    assert detail =~ "points_to.dl"
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

    test "a directory without the file is not an extraction's, and raises naming it",
         %{tmp_dir: dir} do
      path = Path.join(dir, "extraction_error.facts")

      assert_raise Argus.MissingRelationError, ~r/extraction_error relation's file/, fn ->
        Runner.extraction_errors(dir)
      end

      error = catch_error(Findings.extraction_errors(dir))
      assert %Argus.MissingRelationError{relation: "extraction_error", path: ^path} = error
    end

    test "a run over a handed-in directory without the file is an error, not no errors" do
      {:ok, facts} = Argus.Analysis.extract_facts([:lists], [:effects])
      on_exit(fn -> File.rm_rf!(Path.dirname(facts)) end)
      File.rm!(Path.join(facts, "extraction_error.facts"))

      assert {:error, %Argus.MissingRelationError{relation: "extraction_error"}} =
               Runner.run([:lists], analyses: [:effects], facts_dir: facts)
    end
  end
end
