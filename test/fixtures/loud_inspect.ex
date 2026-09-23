defmodule Argus.Test.Fixtures.LoudInspect do
  @moduledoc """
  The shape sequin's CircularBuffer has: an `Inspect` implementation that
  raises on the struct's own defaults, which `inspect/1` renders as a
  multi-line `#Inspect.Error<...>`. Compiled with the project so the
  implementation is part of the consolidated protocol.
  """
  defstruct [:items]

  defimpl Inspect do
    def inspect(%{items: items}, _opts), do: "#Loud<" <> Enum.join(items, ",") <> ">"
  end
end
