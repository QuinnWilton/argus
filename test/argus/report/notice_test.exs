defmodule Argus.Report.NoticeTest do
  use ExUnit.Case, async: true

  alias Argus.Report.Notice

  test "a bounded points-to stage names how many pervasive terms it resolved coarsely" do
    notice = Notice.points_to_bounded(["server A", "spawn B"])
    assert notice.kind == :points_to_bounded
    assert notice.severity == :info
    assert notice.message =~ "ran bounded: 2 pervasive terms were resolved coarsely"
  end

  test "a coarse points-to stage says every term was resolved coarsely" do
    notice = Notice.points_to_coarse(["server A", "spawn B", "start C"])
    assert notice.kind == :points_to_coarse
    assert notice.severity == :info
    assert notice.message =~ "bounded too, and ran coarse"
    assert notice.message =~ "every term holding a process (3) was resolved coarsely"
  end
end
