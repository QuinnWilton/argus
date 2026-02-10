defmodule Argus.Test.Fixtures.LoopsFixture do
  @moduledoc false

  # Tail-recursive countdown (single recursive call in tail position).
  def countdown(0), do: :done

  def countdown(n) when n > 0 do
    countdown(n - 1)
  end

  # Receive loop (blocks on receive, then recurses).
  def receive_loop(state) do
    receive do
      {:update, val} -> receive_loop(val)
      :stop -> state
    end
  end

  # Non-tail recursion (work after the recursive call).
  def sum_list([]), do: 0

  def sum_list([h | t]) do
    h + sum_list(t)
  end
end
