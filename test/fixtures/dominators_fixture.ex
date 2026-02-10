defmodule Argus.Test.Fixtures.DominatorsFixture do
  @moduledoc false

  # Simple diamond CFG: if/else creates two branches that rejoin.
  def diamond(x) do
    y =
      if x > 0 do
        :positive
      else
        :negative
      end

    {:result, y}
  end

  # Linear function (no branches): every instruction dominates all later ones.
  def linear(a, b) do
    c = a + b
    c * 2
  end
end
