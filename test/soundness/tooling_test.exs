defmodule Argus.Soundness.ToolingTest do
  @moduledoc """
  The tooling step leaves the product alone: a Mix task the release runs,
  a `test/` context a controller calls, a sink a request reaches, and
  code execution past a value prior (soundness review 2,
  test/fixtures/soundness/tooling_fixture.ex and lib/).
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  import Argus.Test.Soundness.Case

  alias Argus.Findings

  setup do
    :ok
  end

  test "a Mix task product code calls is the product" do
    sev = severities(modules("tooling_fixture.ex"), [:races, :ets])
    task = "Mix.Tasks.Soundness.G9.Quota"
    assert severity(sev, task, :run, "Read-then-write race") == :warning
    # :info is the class's own severity, which the step cannot lower: the
    # race above is the row that tells a stepped finding from its parent.
    assert severity(sev, task, :run, "read while its owner may be restarting") == :info
  end

  test "a lib/**/test/ module a controller calls is the product" do
    sev =
      severities(
        modules("lib/exam/test/grader.ex") ++ modules("lib/exam_web/grade_controller.ex"),
        [:unsafe_input]
      )

    assert severity(sev, "G9.Exam.Test.Grader", :grade, "code execution") == :error
    assert severity(sev, "G9.Exam.Test.Grader", :tag, "atom creation") == :error
  end

  test "a floor bounds the step and never lifts" do
    index = Findings.Tooling.index([["Mix.Tasks.Seed", "mix", "1000"]])
    at = [at: Findings.at_module("Mix.Tasks.Seed")]

    step =
      &Findings.Tooling.retier(Map.put(Findings.new(&1, "t", "d", at), :floor, &2), index).severity

    # A request's sink keeps its severity; code execution no request
    # reaches, stepped to :warning by a value prior, stays there.
    assert step.(:error, :error) == :error
    assert step.(:warning, :warning) == :warning
    assert step.(:warning, :warning) == :warning
    assert step.(:info, :error) == :info
    assert step.(:error, :info) == :warning
  end
end
