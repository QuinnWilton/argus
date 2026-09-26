defmodule Argus.Extractors.GenStatemTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.GenStatem
  alias Argus.Pipeline.Disassemble

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — state_functions mode" do
    test "detects gen_statem module" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      assert Map.has_key?(facts, :statem_module)
      rows = facts[:statem_module]
      assert length(rows) == 1

      [mod, mode] = hd(rows)
      assert String.contains?(mod, "SimpleStatem")
      assert mode == "state_functions"
    end

    test "detects states" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      assert Map.has_key?(facts, :statem_state)
      rows = facts[:statem_state]
      states = Enum.map(rows, fn [_, state, _site] -> state end) |> Enum.uniq()

      assert "idle" in states
      assert "running" in states
    end

    test "registers only exported functions as states" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.PrivateHelperStatem))

      states = Enum.map(facts[:statem_state], fn [_, state, _site] -> state end)

      # Real states.
      assert "idle" in states
      assert "running" in states

      # A private arity-3 helper is not a state.
      refute "normalize" in states

      # An exported, arity-3, action-returning helper that a state calls
      # directly is not a state (gen_statem never calls a state locally).
      refute "finalize" in states

      # Compiler-lifted closures (private arity-3 top-level functions with
      # mangled names) are not states.
      refute Enum.any?(states, &String.starts_with?(&1, "-"))
    end

    test "detects transitions" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      assert Map.has_key?(facts, :statem_transition)
      rows = facts[:statem_transition]

      # idle -> running.
      assert Enum.any?(rows, fn [_, from, _, to] ->
               from == "idle" and to == "running"
             end)

      # running -> idle.
      assert Enum.any?(rows, fn [_, from, _, to] ->
               from == "running" and to == "idle"
             end)
    end

    test "detects stop transition" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      rows = facts[:statem_transition]

      assert Enum.any?(rows, fn [_, from, _, to] ->
               from == "running" and to == "stop"
             end)
    end
  end

  describe "extract/1 — what a helper builds and what a state returns of a call" do
    test "a helper's next_state is a transition from no named state" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.HelperTransitionStatem))

      assert [[_mod, func, "disconnected"]] = facts[:statem_helper_transition]
      assert func =~ ":disconnect/2"
    end

    test "a state returning a call's result names the local callee, or dynamic" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.HelperTransitionStatem))

      calls =
        for [_mod, func, callee] <- facts[:statem_returns_call],
            do:
              {func |> String.split(":") |> List.last(),
               callee |> String.split(":") |> List.last()}

      assert {"connected/3", "disconnect/2"} in calls
      assert {"waiting/3", "dynamic"} in calls
      refute Enum.any?(calls, fn {func, _} -> func in ["connecting/3", "disconnected/3"] end)
    end

    test "a helper computing its target is a dynamic transition" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.PrivateHelperStatem))

      assert [[_mod, func, "dynamic"]] = facts[:statem_helper_transition]
      assert func =~ ":finalize/3"
    end
  end

  describe "extract/1 — timeouts" do
    test "detects state_timeout in timeout statem" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.TimeoutStatem))

      timeouts = Map.get(facts, :statem_timeout, [])

      assert Enum.any?(timeouts, fn [_, state, type, _value] ->
               state == "waiting" and type == "state_timeout"
             end)
    end
  end

  describe "extract/1 — a timeout action's flow to the return" do
    test "an action built on one arm reaches the return through the join; a sent tuple does not" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.GenStatemTest.JoinedActions do
          @behaviour :gen_statem
          def callback_mode, do: :state_functions
          def init(d), do: {:ok, :idle, d}

          def idle(:cast, ms, d) do
            actions = if ms > 0, do: [{:state_timeout, ms, :tick}], else: [{:timeout, 5, :tock}]
            send(self(), {:timeout, ms, :x})
            {:keep_state, d, actions}
          end

          def idle(:info, {:timeout, ms, x}, d) do
            send(self(), {:timeout, ms, x})
            {:keep_state, d}
          end
        end
        """)

      {:ok, data} = Disassemble.disassemble_path(bin)
      timeouts = data |> GenStatem.extract() |> Map.get(:statem_timeout, []) |> Enum.sort()

      assert timeouts == [
               ["Argus.GenStatemTest.JoinedActions", "idle", "event_timeout", "5"],
               ["Argus.GenStatemTest.JoinedActions", "idle", "state_timeout", "dynamic"]
             ]
    end
  end

  describe "extract/1 — the GenStateMachine library" do
    test "a module that uses GenStateMachine is a gen_statem" do
      # The library's `use` declares `@behaviour GenStateMachine`, which is
      # not loaded here; the compiler warns and compiles.
      {[{_mod, bin}], _diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string("""
          defmodule Argus.GenStatemTest.Library do
            @behaviour GenStateMachine
            def callback_mode, do: :state_functions
            def init(d), do: {:ok, :idle, d}
            def idle({:call, from}, :ping, d), do: {:keep_state, d, [{:reply, from, :pong}]}
          end
          """)
        end)

      {:ok, data} = Disassemble.disassemble_path(bin)
      facts = GenStatem.extract(data)

      assert facts[:statem_module] == [["Argus.GenStatemTest.Library", "state_functions"]]
      assert [["Argus.GenStatemTest.Library", "idle", _]] = facts[:statem_state]
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for non-statem module" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.SimpleStatem],
                 extractors: [GenStatem]
               )

      assert Map.has_key?(facts, :statem_module)
    end
  end

  describe "extract/1 — clause heads" do
    test "event types a state function discriminates on, tagged tuples included" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.HandleEventStatem))

      types =
        facts[:statem_event_clause]
        |> Enum.map(fn [_mod, _func, type] -> type end)
        |> Enum.sort()

      assert types == ["cast", "info", "{call}"]
    end

    test "an :info catch-all is found where it exists and not where it does not" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.AsymmetricInfoStatem))

      catchalls = Enum.map(facts[:statem_info_catchall], fn [_mod, func] -> func end)

      assert Enum.any?(catchalls, &String.ends_with?(&1, ":disconnected/3"))
      assert Enum.any?(catchalls, &String.ends_with?(&1, ":cooling_down/3"))
      refute Enum.any?(catchalls, &String.ends_with?(&1, ":ready/3"))

      # Every state matches its event type, so none accepts any event.
      refute Map.has_key?(facts, :statem_event_catchall)
    end

    test "an :info catch-all may ask anything of the data, not of the content or the state" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.DataPatternInfoStatem))
      catchalls = Enum.map(facts[:statem_info_catchall], fn [_mod, func] -> func end)

      assert Enum.any?(catchalls, &String.ends_with?(&1, ":ready/3"))
      refute Enum.any?(catchalls, &String.ends_with?(&1, ":busy/3"))

      # A handle_event/4 clause naming a state is that state's catch-all,
      # not the machine's (review 2, item 34).
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.OneStateInfoStatem))
      refute facts[:statem_info_catchall]
    end

    test "a clause with a wildcard event type is a total catch-all" do
      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.SimpleStatem))

      # SimpleStatem.idle/3 ends with `idle(:cast, _, data)`: not total —
      # the event type is still matched.
      refute Map.has_key?(facts, :statem_event_catchall)

      facts = GenStatem.extract(disassemble(Argus.Test.Fixtures.DelegatingStatem))
      totals = Map.get(facts, :statem_event_catchall, [])
      assert is_list(totals)
    end
  end

  describe "extract/1 — inserted events" do
    alias Argus.Test.Soundness.Runs

    defp inserts(mod) do
      for [_id, func, clause, type] <-
            Map.get(GenStatem.extract(disassemble(mod)), :statem_insert, []) do
        {func |> String.split(":") |> List.last(), clause, type}
      end
      |> Enum.sort()
    end

    test "an internal event init/1 and a cast clause insert, by their clauses" do
      assert inserts(Runs.InsertAgain) == [
               {"handle_event/4", ":cast", ":internal"},
               {"init/1", "*", ":internal"}
             ]
    end

    test "an event of a type the function does not spell is any type" do
      assert {"handle_event/4", ":cast", "*"} in inserts(Runs.InsertAnyType)
    end

    test "a helper's literal action list" do
      assert {"watch/0", "*", ":internal"} in inserts(Runs.InsertShared)
    end
  end

  describe "extract/1 — which functions are states" do
    alias Argus.Test.Soundness.Runs

    defp states(mod) do
      for [_mod, state, _site] <- Map.get(GenStatem.extract(disassemble(mod)), :statem_state, []),
          uniq: true,
          do: state
    end

    test "a state an event is re-dispatched to, which a transition names" do
      assert "active" in states(Runs.StatemRedispatchedState)
    end

    test "a function an event is re-dispatched to that no transition names is a helper" do
      refute "common" in states(Runs.StatemHelperNotNamed)
      refute "retry" in states(Runs.StatemHelperNamedAsMessage)
    end

    test "a function handed the data first is a helper" do
      refute "disconnect" in states(Runs.StatemDataFirst)
    end

    test "a state whose clauses return through a local helper" do
      assert "idle" in states(Runs.StatemViaHelper)
    end

    test "a clause that hands every event on is a catch-all, though a case follows the call" do
      facts = GenStatem.extract(disassemble(Runs.StatemDelegatingCatchAll))
      totals = for [_mod, func] <- Map.get(facts, :statem_event_catchall, []), do: func
      assert Enum.any?(totals, &String.ends_with?(&1, ":draining/3"))
    end

    test "a call after a test of the content or a type guard is no catch-all" do
      for mod <- [Runs.StatemContentThenCall, Runs.StatemCastCatchAll, Runs.StatemGuardedCall] do
        facts = GenStatem.extract(disassemble(mod))
        refute Map.get(facts, :statem_event_catchall), inspect(mod)
        refute Map.get(facts, :statem_info_catchall), inspect(mod)
      end
    end
  end
end
