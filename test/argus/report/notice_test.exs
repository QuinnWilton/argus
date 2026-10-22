defmodule Argus.Report.NoticeTest do
  use ExUnit.Case, async: true

  alias Argus.Report.Notice

  test "a selective points-to stage names how many hub objects it resolved field-insensitively" do
    notice = Notice.points_to_selective(["server A", "spawn B"])
    assert notice.kind == :points_to_selective
    assert notice.severity == :info

    assert notice.message =~
             "ran selective: 2 hub objects (processes or tables) were resolved field-insensitively"
  end

  test "a field-insensitive points-to stage says every object was resolved so" do
    notice = Notice.points_to_field_insensitive(["server A", "spawn B", "start C"])
    assert notice.kind == :points_to_field_insensitive
    assert notice.severity == :info
    assert notice.message =~ "selective too, and ran field-insensitive"

    assert notice.message =~
             "every process and table (3) was resolved field-insensitively"
  end

  test "an ignore entry for a set is not judged when one of its analyses degraded" do
    config = Argus.Config.load(ignore: [findings: [{:otp, {String, :trim, 1}}]])
    [%{analyses: analyses}] = config.ignore_findings
    [degraded | rest] = analyses

    located = Map.new(rest, &{&1, {:ok, []}}) |> Map.put(degraded, {:error, :timeout})
    result = %Argus.Driver.Result{located: located, notices: [], changed?: false}

    refute Enum.any?(Notice.from_result(result, config, "."), &(&1.kind == :unused_ignore))

    ok = %{result | located: Map.new(analyses, &{&1, {:ok, []}})}
    assert Enum.any?(Notice.from_result(ok, config, "."), &(&1.kind == :unused_ignore))
  end
end
