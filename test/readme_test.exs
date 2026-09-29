defmodule Argus.ReadmeTest do
  @moduledoc """
  The README's analysis table lists the analyses `:all` names and marks
  the `:default` set, so an analysis added or a default changed cannot
  leave the table behind. Its descriptions are the README's own short
  summaries; `argus list` prints each analysis's full `description/0`.
  """

  use ExUnit.Case, async: true

  alias Argus.Analysis

  test "the analysis table lists every analysis in :all and marks the :default set" do
    rows =
      for [_, name, default] <-
            Regex.scan(~r/^\| `([a-z_]+)` \| .+ \| *(✓?) *\|$/mu, File.read!("README.md")),
          into: %{},
          do: {String.to_atom(name), default == "✓"}

    sets = Analysis.sets()

    assert rows == Map.new(sets.all, &{&1, &1 in sets.default})
  end
end
