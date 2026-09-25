defmodule Argus.Analyses.BlockingPidCallTest do
  use ExUnit.Case, async: true

  alias Argus.Test.Fixtures.PidCalls
  alias Argus.Test.Memo
  alias Argus.Test.Rows

  setup do
    unless Argus.Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  defp analyze do
    {:ok, r} =
      Memo.analyze(
        [PidCalls.Waiter, PidCalls.Slow, PidCalls.Impatient, PidCalls.Middle, PidCalls.Tail],
        :blocking
      )

    r
  end

  test "an :infinity call through a pid the server started is an unbounded hop" do
    # Waiter keeps the Slow it started in its state; the call's target is
    # the pid, which points-to follows back to Slow's start.
    assert [[func, site, "infinity", slow, "", ""]] =
             Rows.where(analyze(), :blocking, "unbounded_wait",
               kind: "infinity",
               drop: [:peer, :permille]
             )

    assert func == "#{inspect(PidCalls.Waiter)}:handle_call/3"
    assert slow == inspect(PidCalls.Slow)

    # Anchored at the waiting call in the handler, not at its head.
    assert site =~ "#{inspect(PidCalls.Waiter)}:handle_call/3#"
  end

  test "a chain whose hops points-to proves is not marked inferred" do
    # Middle's call to Tail carries :ask, which Middle and Tail both
    # name; points-to resolves it, so the tag is not what proves the hop.
    assert [[_, _, 2, "static", 0, 0]] =
             analyze()
             |> Rows.where(:blocking, "call_chain",
               kind: "chain",
               drop: [:kind, :peer, :permille, :site]
             )
             |> Enum.map(fn [a, b, d, i, c, w] ->
               [a, b, String.to_integer(d), i, String.to_integer(c), String.to_integer(w)]
             end)
  end

  test "a budget through pids: one second for a callee that waits five" do
    assert [[impatient, middle, 1, _, 1_000, 5_000]] =
             analyze()
             |> Rows.where(:blocking, "call_chain",
               kind: "budget",
               drop: [:kind, :peer, :permille, :site]
             )
             |> Enum.map(fn [a, b, d, i, c, w] ->
               [a, b, String.to_integer(d), i, String.to_integer(c), String.to_integer(w)]
             end)

    assert impatient == inspect(PidCalls.Impatient)
    assert middle == inspect(PidCalls.Middle)
  end

  test "a gen_statem's data carries the pid its state function calls" do
    {:ok, r} = Memo.analyze([PidCalls.StatemFront, PidCalls.StatemPeer], :blocking)

    # StatemFront calls the StatemPeer it keeps in its data; StatemPeer
    # calls StatemFront by name. The first edge is the data's, not a guess
    # from the :ping tag and StatemFront's reference to StatemPeer.
    assert [[a, b | _]] = Rows.where(r, :blocking, "call_cycle", phase: "call")
    assert Enum.sort([a, b]) == [inspect(PidCalls.StatemFront), inspect(PidCalls.StatemPeer)]

    front = inspect(PidCalls.StatemFront)

    assert [[^front, "static"]] =
             r
             |> Rows.where(:blocking, "call_cycle_path", from_mod: front)
             |> Enum.map(fn [_, _, from, _, _, how, _] -> [from, how] end)
             |> Enum.uniq()
  end

  test "a closure beside a child spec's fun is the handler's own" do
    {:ok, r} = Memo.analyze([PidCalls.HandOffCaster, PidCalls.Named], :blocking)

    assert [[caster, named | _]] =
             Rows.where(r, :blocking, "call_chain", kind: "cast", drop: [:peer, :permille, :site])

    assert {caster, named} == {inspect(PidCalls.HandOffCaster), inspect(PidCalls.Named)}
  end
end
