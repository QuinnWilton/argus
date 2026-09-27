defmodule Argus.Report.TextColorTest do
  @moduledoc """
  `--color`: `:always` colors the frames even into a pipe, `:never`
  leaves them plain, and the two differ by the escape codes alone.
  """

  # `color: :always` enables ANSI for the VM while it renders: a test
  # beside it could see its own frames colored.
  use ExUnit.Case, async: false

  alias Argus.Report
  alias Argus.Test.ReportShapes

  test "text colors as asked" do
    cwd = ReportShapes.root()
    entries = Report.build(ReportShapes.located(), Argus.Config.load(ReportShapes.config()), cwd)

    plain = Report.Text.format(entries, [], cwd, color: :never)
    colored = Report.Text.format(entries, [], cwd, color: :always)

    refute plain =~ "\e["
    assert colored =~ "\e["
    assert String.replace(colored, ~r/\e\[[0-9;]*m/, "") == plain
  end
end
