defmodule Argus.ReadmeTest do
  @moduledoc """
  The README's analysis table is the one `mix scry --list` prints: each
  row is an analysis's `description/0`, so a concern that grows a rule
  cannot leave the table behind.
  """

  use ExUnit.Case, async: true

  alias Argus.Analysis

  test "the analysis table lists every analysis with its description" do
    rows =
      for [_, name, description] <-
            Regex.scan(~r/^\| `([a-z_]+)` \| (.+) \|$/m, File.read!("README.md")),
          into: %{},
          do: {String.to_atom(name), String.replace(description, "`", "")}

    expected = Map.new(Analysis.builtin_analysis_modules(), &{&1.name(), &1.description()})

    assert rows == expected
  end
end
