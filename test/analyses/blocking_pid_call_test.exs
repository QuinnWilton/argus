defmodule Argus.Analyses.BlockingPidCallTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.PidCalls
  alias Argus.Test.Rows

  setup do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  defp analyze do
    {:ok, r} =
      Argus.analyze(
        [PidCalls.Waiter, PidCalls.Slow, PidCalls.Impatient, PidCalls.Middle, PidCalls.Tail],
        :blocking
      )

    r
  end

  test "an :infinity call through a pid the server started is an unbounded hop" do
    # Waiter keeps the Slow it started in its state; the call's target is
    # the pid, which points-to follows back to Slow's start.
    assert [[func, "", "infinity", slow, ""]] =
             Rows.where(analyze(), :blocking, "unbounded_wait", kind: "infinity")

    assert func == "#{inspect(PidCalls.Waiter)}:handle_call/3"
    assert slow == inspect(PidCalls.Slow)
  end

  test "a budget through pids: one second for a callee that waits five" do
    assert [[impatient, middle, 1, _, 1_000, 5_000]] =
             analyze()
             |> Rows.where(:blocking, "call_chain", kind: "budget", drop: [:kind])
             |> Enum.map(fn [a, b, d, i, c, w] ->
               [a, b, String.to_integer(d), i, String.to_integer(c), String.to_integer(w)]
             end)

    assert impatient == inspect(PidCalls.Impatient)
    assert middle == inspect(PidCalls.Middle)
  end
end
