defmodule Scry.AnalysisRelatedTest do
  @moduledoc """
  Related frames resolve like findings: the bytecode anchor, then the
  frame's own source fragment (`at_source`) the last step.
  """

  use ExUnit.Case, async: true

  alias Scry.Test.Graph

  @moduletag :souffle
  @moduletag timeout: 300_000

  test "an unreceived message's receive frame lands on the receive" do
    paths = Graph.parity!()
    db = Graph.new_db(paths)

    {:ok, by_file} = Scry.Analysis.analysis_diagnostics(db, :mailbox)

    [{file, entries}] =
      Enum.filter(by_file, fn {file, _} ->
        String.ends_with?(file, "unreceived_message_fixture.ex")
      end)

    source = file |> File.read!() |> String.split("\n")

    # Shop.checkout/1 sends :checked_out to the Audit loop, whose receive
    # takes only :paid. Titles carry no instance values (argus 1721917),
    # so the fixture's three unreceived messages share one title: the
    # anchor's label names the message.
    assert [finding] = Enum.filter(entries, &(&1.at_label == ":checked_out is sent here"))
    assert finding.title == "Message sent to a process whose receive never takes it"

    assert [frame] = Enum.filter(finding.related, &(&1.label =~ "receive it never matches"))

    # On the receive, bracketed to its last clause (`to_block: :receive`).
    assert Enum.at(source, frame.line - 1) =~ ~r/^\s*receive do/
    assert Enum.at(source, frame.end_line - 1) =~ ~r/^\s*:paid -> loop\(\)/
  end
end
