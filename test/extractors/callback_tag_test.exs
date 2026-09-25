defmodule Argus.Extractors.CallbackTagTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.CallbackTag
  alias Argus.Test.Fixtures.UnhandledInfo, as: U

  defp facts(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [CallbackTag])
    short = &String.replace(&1, "Argus.Test.Fixtures.UnhandledInfo.", "")

    %{
      drops: for([f, "handle_info"] <- Map.get(facts, :callback_drops, []), do: short.(f)),
      open: for([f, "handle_info", s] <- Map.get(facts, :callback_open, []), do: {short.(f), s}),
      shapes:
        for(
          [f, "handle_info", tag, arity] <- Map.get(facts, :callback_tag_shape, []),
          do: {short.(f), tag, arity}
        )
    }
  end

  test "a clause head takes a tag as the atom or as a tuple of its arity" do
    %{shapes: shapes} = facts([U.WarmUp, U.Retry])
    # handle_info({:put, origin, key, value}, _) and handle_info(:expire, _).
    assert {"WarmUp:handle_info/2", ":put", "4"} in shapes
    assert {"WarmUp:handle_info/2", ":expire", "0"} in shapes
    refute {"WarmUp:handle_info/2", ":expire", "2"} in shapes
  end

  test "a clause takes every message of its shape only when it pins and compares nothing" do
    alias Argus.Test.Fixtures, as: F

    every = fn mod ->
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      for(
        [_f, "handle_info", tag, arity] <-
          Map.get(CallbackTag.extract(data), :callback_takes_every, []),
        do: {tag, arity}
      )
      |> Enum.sort()
    end

    # `{:DOWN, ref, :process, _, _}` against a `%__MODULE__{}` state: every
    # process monitor's :DOWN.
    assert every.(F.MonitorsTakingEveryDown) == [{":DOWN", "5"}]
    assert every.(F.TrapsTakingEveryExit) == [{":DOWN", "5"}, {":EXIT", "3"}]
    # The ref pinned to the state, a state field compared, one exit reason.
    assert every.(F.MonitorsWithoutCatchall) == []
    assert every.(F.MonitorsDownWhenActive) == []
    assert every.(F.TrapsTakingNormalExits) == [{":DOWN", "5"}]
  end

  test "a catch-all that ignores or logs the message drops it; one that hands it on does not" do
    %{drops: drops} = facts([U.Listeners, U.Repair, U.Ticker, U.Delegates, U.Handled])
    assert "Listeners:handle_info/2" in drops
    assert "Repair:handle_info/2" in drops
    # GenServer's own handle_info/2 logs and drops.
    assert "Ticker:handle_info/2" in drops
    refute "Delegates:handle_info/2" in drops
    # No catch-all at all.
    refute "Handled:handle_info/2" in drops
  end

  test "a clause that tests the message by shape alone is open" do
    %{open: open} = facts([U.OpenClause, U.Handled, U.Listeners])
    assert {"OpenClause:handle_info/2", "any"} in open
    assert {"OpenClause:handle_info/2", "tuple"} in open
    # :refresh and {:DOWN, ...} are compared by value; a catch-all is not a clause
    # that is open.
    refute Enum.any?(open, &match?({"Handled:handle_info/2", _}, &1))
    refute Enum.any?(open, &match?({"Listeners:handle_info/2", _}, &1))
  end
end
