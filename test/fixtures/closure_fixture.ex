defmodule Argus.Test.Fixtures.ClosureModule do
  @moduledoc false

  # The Elixir compiler lifts each anonymous function into a top-level
  # function with a name like `:"-spans_telemetry/1-fun-0-"`. The lifted
  # body is referenced from `make_fun3` with a concrete `{Module, Func, Arity}`
  # triple, which Argus turns into a `closure_def` fact connecting the
  # parent function to the lifted body.

  def spans_telemetry(value) do
    :telemetry.span([:fixture, :work], %{}, fn ->
      result = inner_work(value)
      {result, %{}}
    end)
  end

  def maps_through_enum(items) do
    Enum.map(items, fn item -> inner_work(item) end)
  end

  def inner_work(value), do: {:ok, value}
end
