defmodule Argus.Report.NoticeTest do
  use ExUnit.Case, async: true

  alias Argus.Report.Notice

  test "a selective points-to stage names how many hub terms it resolved field-insensitively" do
    notice = Notice.points_to_selective(["server A", "spawn B"])
    assert notice.kind == :points_to_selective
    assert notice.severity == :info
    assert notice.message =~ "ran selective: 2 hub terms were resolved field-insensitively"
  end

  test "a field-insensitive points-to stage says every term was resolved so" do
    notice = Notice.points_to_field_insensitive(["server A", "spawn B", "start C"])
    assert notice.kind == :points_to_field_insensitive
    assert notice.severity == :info
    assert notice.message =~ "selective too, and ran field-insensitive"

    assert notice.message =~
             "every term holding a process (3) was resolved field-insensitively"
  end
end
