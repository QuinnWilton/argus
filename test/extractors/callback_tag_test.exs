defmodule Argus.Extractors.CallbackTagTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.CallbackTag
  alias Argus.Test.Fixtures.UnhandledInfo, as: U

  defp facts(modules) do
    {:ok, facts} = Argus.Pipeline.extract(modules, extractors: [CallbackTag])
    short = &String.replace(&1, "Argus.Test.Fixtures.UnhandledInfo.", "")

    %{
      drops: for([f, "handle_info"] <- Map.get(facts, :callback_drops, []), do: short.(f)),
      open:
        for(
          [f, "handle_info", s, _arity] <- Map.get(facts, :callback_open, []),
          do: {short.(f), s}
        ),
      arities:
        for(
          [f, "handle_info", s, arity] <- Map.get(facts, :callback_open, []),
          do: {short.(f), s, arity}
        ),
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

  test "a :DOWN clause takes every reason unless it tests the reason" do
    alias Argus.Test.Fixtures, as: F
    alias Argus.Test.Soundness.Witness, as: W

    down = fn mod ->
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      for [_f, "handle_info", type] <-
            Map.get(CallbackTag.extract(data), :callback_takes_down, []),
          do: type
    end

    # The ref pinned to the state and a state field compared are the
    # program's: the clause takes its monitors' :DOWN, whatever the reason.
    assert down.(F.MonitorsTakingEveryDown) == ["process"]
    assert down.(F.MonitorsWithoutCatchall) == ["process"]
    assert down.(F.MonitorsDownWhenActive) == ["process"]
    # A :normal clause and a catch-all reason clause take every reason
    # between them; so does a clause that decides on the reason in its body.
    assert down.(W.DownSplitReasons) == ["process"]
    assert down.(W.DownReasonInBody) == ["process"]
    # The type left alone takes a port's :DOWN too.
    assert down.(W.PortDownAnyType) == ["any"]
    # A reason literal, a guard on it or a pattern leaves the runtime's other
    # reasons to no clause.
    for mod <- [
          W.DownOnlyNormal,
          W.DownGuardIn,
          W.DownShutdownOnly,
          F.MonitorsDownGuardedByReason
        ] do
      assert down.(mod) == [], inspect(mod)
    end
  end

  test "a trapped :EXIT is taken whatever its reason unless the clause tests the reason" do
    alias Argus.Test.Fixtures, as: F
    alias Argus.Test.Soundness.Witness, as: W

    exit? = fn mod ->
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      Map.has_key?(CallbackTag.extract(data), :callback_takes_exit)
    end

    # `from` pinned to the state is the program's; the reason is not.
    assert exit?.(W.ExitEveryReason)
    assert exit?.(F.TrapsTakingEveryExit)
    refute exit?.(W.ExitNormalOnly)
    refute exit?.(W.ExitPinnedNormal)
    refute exit?.(W.ExitShutdownOnly)
    refute exit?.(F.TrapsTakingNormalExits)
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

  test "a guard's element/2 of the message compares its tag: the clause is not open" do
    alias Argus.Test.Soundness.Witness, as: W

    {:ok, facts} = Argus.Pipeline.extract([W.ExitBesideGuardedTag], extractors: [CallbackTag])

    refute Map.has_key?(facts, :callback_open)

    assert ["_", "handle_info", ":trace_ts", "-1"] in Enum.map(
             facts[:callback_tag_shape],
             &["_" | tl(&1)]
           )
  end

  test "an open tuple clause carries the arity its head tests" do
    alias Argus.Test.Soundness.Witness, as: W

    {:ok, facts} = Argus.Pipeline.extract([W.NolinkReplyOnly], extractors: [CallbackTag])

    # `{ref, result} when is_reference(ref)` takes 2-tuples: no :DOWN.
    assert for([_f, "handle_info", s, a] <- facts[:callback_open], do: {s, a}) == [{"tuple", "2"}]
  end

  test "a pair that fails its clause's guard enters no clause open to atoms" do
    {:ok, facts} =
      Argus.Pipeline.extract([Argus.Test.Fixtures.MailboxOpenRequestShape],
        extractors: [CallbackTag]
      )

    # `{op, arg} when is_atom(op)`, then `cmd when is_atom(cmd)`: a pair
    # whose first element is no atom falls to the second clause, which
    # it does not pass. The clauses are open to pairs and to atoms, and
    # to no tuple of another arity.
    assert for([_f, "handle_call", s, a] <- facts[:callback_open], do: {s, a}) |> Enum.sort() ==
             [{"any", "-1"}, {"tuple", "2"}]
  end
end
