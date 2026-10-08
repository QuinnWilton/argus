defmodule Argus.Extractors.ErrorHandlingTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ErrorHandling
  alias Argus.Pipeline.Disassemble

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  # Rows whose first column is an instruction id, by function: the id is
  # matched against its function rather than spelled, since its index
  # moves with the compiler.
  defp by_function(rows) do
    rows
    |> Enum.map(fn [id, func | rest] ->
      assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
      [func |> String.split(":") |> List.last() | rest]
    end)
    |> Enum.sort()
  end

  describe "extract/1 — bare rescue" do
    test "detects bare catch that swallows all exceptions" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.BareRescue))

      # A bare disassembly carries no Line table, so the handler's span
      # has no end.
      assert by_function(facts[:bare_rescue]) == [["swallow_all/1", ""]]
    end

    test "does not flag rescue with exception class filtering" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.FilteredRescue))

      bare = Map.get(facts, :bare_rescue, [])
      assert bare == []
    end

    test "returning exception data in a tuple, map, closure or directly is not swallowing it" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ReifyingRescue))
      assert Map.get(facts, :bare_rescue, []) == []
    end
  end

  describe "extract/1 — returned_update" do
    alias Argus.Test.Fixtures.Restart

    defp updates(mod) do
      mod
      |> disassemble()
      |> ErrorHandling.extract()
      |> Map.get(:returned_update, [])
      |> Enum.map(fn [func, key, value, tag] ->
        {func |> String.split(":") |> List.last(), key, value, tag}
      end)
      |> Enum.sort()
    end

    test "an Erlang record's fields, by position: an update in its clause, and the state init/1 builds" do
      assert updates(:restart_record_keeper) == [
               {"handle_call/3", "{1}", "dynamic", ":register"},
               {"init/1", "{1}", "[]", "*"},
               {"init/1", "{2}", "0", "*"}
             ]
    end

    test "a record the compiler builds afresh for a one-field update is read in the state slot" do
      assert {"handle_cast/2", "{1}", ":none", ":invalidate"} in updates(:restart_reset_keeper)
    end

    test "a state its fields do not spell is the whole state, and a read clause sets nothing" do
      assert updates(Restart.ComputedKeeper) == [
               {"handle_call/3", "*", "dynamic", ":add_handler"}
             ]

      assert updates(Restart.ClauseKeeper) == [
               {"handle_call/3", ":pids", "dynamic", ":put"},
               {"init/1", ":pids", "[]", "*"}
             ]
    end

    test "a literal is spelled as the column spells it" do
      assert updates(Restart.FlagKeeper) == [
               {"handle_cast/2", ":ready", "true", ":ready"},
               {"init/1", ":ready", "false", "*"}
             ]
    end
  end

  describe "extract/1 — timer_tag" do
    alias Argus.Test.Fixtures.UnhandledInfo

    defp tags(mod) do
      facts = ErrorHandling.extract(disassemble(mod))
      arms = Map.new(facts[:timer_arm], fn [id, func | _] -> {id, func} end)

      for [id, tag, arity] <- Map.get(facts, :timer_tag, []) do
        {arms |> Map.fetch!(id) |> String.split(":") |> List.last(), tag, arity}
      end
      |> Enum.sort()
    end

    test "an atom, a literal tuple and a built tuple are told apart by their tag and arity" do
      assert tags(UnhandledInfo.WarmUp) == [
               {"handle_info/2", ":expire", "0"},
               {"handle_info/2", ":warm_up", "2"},
               {"init/1", ":expire", "0"},
               {"init/1", ":warm_up", "2"}
             ]

      assert tags(UnhandledInfo.Retry) == [
               {"handle_info/2", ":backoff", "2"},
               {"init/1", ":retry", "2"}
             ]
    end

    test "a message that is neither an atom nor a tagged tuple has no tag" do
      assert tags(UnhandledInfo.Unjudged) == []
    end
  end

  describe "extract/1 — start_timer_arm" do
    alias Argus.Test.Soundness.Witness, as: W

    defp start_timers(mod) do
      facts = ErrorHandling.extract(disassemble(mod))
      name = &(&1 |> String.split(":") |> List.last())
      for [_id, func, target] <- Map.get(facts, :start_timer_arm, []), do: {name.(func), target}
    end

    test "whose mailbox :erlang.start_timer's {:timeout, ref, msg} lands in" do
      assert start_timers(W.StartTimerMessageClause) == [{"init/1", "self"}]
      assert start_timers(W.Timers) == [{"arm/2", "self"}]
      assert start_timers(W.StartTimerElsewhere) == [{"init/1", "other"}]
      # A send_after is a timer_arm, not a start_timer.
      assert start_timers(Argus.Test.Fixtures.UnhandledInfo.WarmUp) == []
    end
  end

  describe "extract/1 — recv_shape" do
    alias Argus.Test.Soundness.Witness, as: W

    defp shapes(mod) do
      facts = ErrorHandling.extract(disassemble(mod))
      name = &(&1 |> String.split(":") |> List.last())
      for [_id, func, shape] <- Map.get(facts, :recv_shape, []), do: {name.(func), shape}
    end

    test "a receive's clauses by shape, for a receive that waits" do
      # `{^ref, _}`: a tuple whose first element is a value the function holds.
      assert shapes(W.LateSpawnReply) == [{"handle_info/2", "{ref, …}"}]
      assert shapes(W.Waiting) == [{"wait_ready/3", "map"}]
      assert shapes(W.LateSubscriptionTagged) == [{"init/1", "{:ready, …}"}]
      # A wait with no `after` is a receive that waits too.
      assert shapes(W.SpawnBlockingWait) == [{"handle_call/3", "{ref, …}"}]
      # An `after 0` poll takes what is there and waits for nothing.
      assert shapes(W.SpawnPoll) == []
    end
  end

  describe "extract/1 — returns_call" do
    test "a function returns a local callee's result only from a tail call" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ReturnsCall))
      mod = "Argus.Test.Fixtures.ReturnsCall"

      assert ["#{mod}:arm/1", "#{mod}:schedule/1"] in facts[:returns_call]
      log = "#{mod}:log/1"
      refute Enum.any?(facts[:returns_call], &match?([^log, _], &1))
    end
  end

  describe "extract/1 — try_call" do
    test "names the guarded call's own instruction beside the try" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.CatchShapes.NoprocOnly))

      assert [[try_id, func, "GenServer:call/2", call, guard_end]] = facts[:try_call]
      assert func =~ "sync_with_parent/1"
      assert {:ok, %{idx: try_idx}} = Argus.InstrId.parse(try_id)
      assert {:ok, %{idx: call_idx}} = Argus.InstrId.parse(call)
      assert call_idx > try_idx
      # A bare disassembly carries no Line table, so no span can be drawn.
      assert guard_end == ""
    end

    # The catch's last marked line is three below the call in both: in
    # NoprocLogged the try is in tail position; in NoprocThenMore it is
    # not, and the span stops at the catch's send/2 (the literal after it
    # has no marker), not at the send/2 seven lines further on. A catch
    # whose body is a literal gets no line of its own from the compiler;
    # the span then stays on the call.
    test "with the Line table, the span ends on the catch's last marked line" do
      for mod <- [
            Argus.Test.Fixtures.CatchShapes.NoprocLogged,
            Argus.Test.Fixtures.CatchShapes.NoprocThenMore
          ] do
        {:ok, facts} =
          Argus.Pipeline.extract([to_string(:code.which(mod))],
            format: :typed,
            extractors: [ErrorHandling]
          )

        lines = Map.new(facts.line_info, &{{&1.id.func, &1.id.arity, &1.id.idx}, &1.line})

        line_of = fn
          %Argus.InstrId{} = i ->
            lines[{i.func, i.arity, i.idx}]

          id ->
            {:ok, i} = Argus.InstrId.parse(id)
            lines[{i.func, i.arity, i.idx}]
        end

        assert [%{id: try_id, call: call, guard_end: guard_end}] = facts.try_call
        assert {mod, line_of.(guard_end)} == {mod, line_of.(call) + 3}

        # The handler's own row ends its span at the same place.
        assert [%{span_end: ^guard_end}] = Enum.filter(facts.catch_class, &(&1.id == try_id))
      end
    end
  end

  describe "extract/1 — try_covers_closure" do
    alias Argus.Test.Fixtures.Consistency, as: C

    defp covered_closures(mod) do
      {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [ErrorHandling])
      Enum.map(facts[:try_covers_closure] || [], fn [_try, _func, closure] -> closure end)
    end

    test "a closure only calls inside the try read is covered, wherever it is built" do
      # The compiler builds ClosureInTry's closure before the try.
      assert [closure] = covered_closures(C.ClosureInTry)
      assert closure =~ "ClosureInTry:-d/1-fun-0-/1"
    end

    test "a closure whose value leaves the try is not" do
      assert covered_closures(C.ClosureEscapes) == []
    end
  end

  describe "extract/1 — raise_source" do
    alias Argus.Test.Fixtures.MailboxYieldNamedSend
    alias Argus.Test.Fixtures.MailboxYieldRescueOnly
    alias Argus.Test.Fixtures.MailboxYieldSafeCallback
    alias Argus.Test.Fixtures.MailboxYieldStopTask

    defp raise_sources(mod, func) do
      {:ok, facts} = Argus.Pipeline.extract([mod], extractors: [ErrorHandling])
      for [f, via] <- facts[:raise_source], f == inspect(mod) <> ":" <> func, do: via
    end

    test "a body that sends to a pid and receives raises nothing" do
      assert raise_sources(MailboxYieldStopTask, "-handle_call/3-fun-0-/1") == []
    end

    test "a send to a literal name raises on its own" do
      assert raise_sources(MailboxYieldNamedSend, "-stop_reader/1-fun-0-/0") == ["self"]
    end

    test "a try taking every class covers its calls; the handler's own calls are the function's" do
      assert raise_sources(MailboxYieldSafeCallback, "safe_callback/3") ==
               ["Exception:normalize/3"]
    end

    test "a rescue alone covers nothing: the apply raises through, and the handler re-raises" do
      sources = raise_sources(MailboxYieldRescueOnly, "rescued_callback/3")
      assert ":erlang:apply/3" in sources
    end
  end

  describe "extract/1 — try_covers" do
    alias Argus.Extractor.Helpers
    alias Argus.Test.Fixtures.SiblingGuard, as: G

    # {try index, callee, kind} for every call a try in `name/arity` covers.
    defp covered(mod, name, arity) do
      data = disassemble(mod)
      instrs = Helpers.find_function(data.functions, name, arity)
      func = Argus.InstrId.func_id(mod, name, arity)

      data
      |> ErrorHandling.extract()
      |> Map.get(:try_covers, [])
      |> Enum.filter(fn [_try, f, _call, _kind] -> f == func end)
      |> Enum.map(fn [try_id, ^func, call, kind] ->
        {:ok, %{idx: try_idx}} = Argus.InstrId.parse(try_id)
        {:ok, %{idx: call_idx}} = Argus.InstrId.parse(call)
        {try_idx, callee(Enum.at(instrs, call_idx)), kind}
      end)
      |> Enum.sort()
    end

    defp callee(instr) do
      with :none <- Helpers.match_remote_call(instr),
           :none <- Helpers.match_local_call(instr) do
        :dynamic
      else
        {:ok, m, f, a} -> "#{inspect(m)}.#{f}/#{a}"
      end
    end

    @unregister "Argus.Test.Fixtures.SiblingGuard.Directory.unregister/1"

    test "a call inside the try is covered" do
      assert [{_try, @unregister, "try"}] = covered(G.CallInside, :terminate, 2)
    end

    test "a call after the try's end is not" do
      assert [{_try, "GenServer.stop/2", "try"}] = covered(G.TryElsewhere, :terminate, 2)
    end

    test "a call inside nested tries is covered by both" do
      assert [{outer, @unregister, "try"}, {inner, @unregister, "try"}] =
               covered(G.NestedOuterExit, :terminate, 2)

      assert outer < inner
    end

    test "a call after an inner try's end is covered by the outer one alone" do
      assert [
               {outer, @unregister, "try"},
               {outer, "GenServer.stop/2", "try"},
               {inner, "GenServer.stop/2", "try"}
             ] = covered(G.NestedAfterInner, :terminate, 2)

      assert outer < inner
    end

    test "Erlang's catch covers the expression it wraps, and no more" do
      assert [{_catch, ":ets.lookup/2", "catch"}] = covered(:ets_catch_reader, :lookup, 1)
      assert covered(:ets_catch_reader, :peek, 1) == []
    end
  end

  describe "extract/1 — trap_exit" do
    test "names the call, so a rule can ask what runs after it" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.TrapExitModule))

      assert [[id, func, _mod]] = facts[:trap_exit]
      assert func =~ "init/1"
      assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
    end

    test "a literal false is a clear, a computed flag is neither" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.TrapScopedModule))
      mod = "Argus.Test.Fixtures.TrapScopedModule"

      # restore/1's flag is computed: it is in neither relation.
      assert by_function(facts[:trap_exit]) == [["with_trap/1", mod]]
      assert by_function(facts[:untrap_exit]) == [["with_trap/1", mod]]
    end
  end

  describe "extract/1 — exit calls" do
    test "Process.exit/2 names its target, :erlang.exit/1 exits the caller" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ExitCaller))

      assert by_function(facts[:exit_call]) == [
               ["exit_self/0", "self"],
               ["kill/1", "dynamic"]
             ]
    end
  end

  describe "extract/1 — ignored error results" do
    test "a start whose result the next instruction overwrites; a matched one is not" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.IgnoredResultModule))

      # checked_start/0 matches its result. A start whose result is handed
      # on (to Enum.each, a dropped Enum.map, a helper) is result_lost's
      # to read; a comprehension whose list is dropped never conses it.
      assert by_function(facts[:ignored_error_result]) == [
               ["-comprehension_dropped_start/1-fun-1-/2", "Agent.start_link/1"],
               ["-filtered_dropped_start/1-fun-1-/2", "Agent.start_link/1"],
               ["-two_generators_dropped_start/2-fun-1-/3", "Agent.start_link/1"],
               ["ignored_start/0", "GenServer.start_link/2"]
             ]
    end
  end

  describe "timer targets, read through the writes that reach" do
    alias Argus.Test.Fixtures.Instr, as: Fixture

    defp target(fragment) do
      for [_id, func, target | _] <- ErrorHandling.extract(disassemble(Fixture))[:timer_arm],
          String.contains?(func, fragment),
          do: target
    end

    test "self() moved about is still self" do
      assert target("self_timer/1") == ["self"]
    end

    test "self() on one path only is not self" do
      assert target("timer_either/2") == ["other"]
    end
  end

  describe "extract/1 — where an armed timer's ref goes" do
    test "a ref handed to a helper goes where the helper puts it" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.ErrorHandlingTest.TimerHelpers do
          use GenServer
          def init(s), do: {:ok, s}

          def handle_info(:arm, state) do
            ref = Process.send_after(self(), :tick, 1000)
            {:noreply, put_timer(state, ref)}
          end

          def handle_info(:rearm, state) do
            ref = Process.send_after(self(), :tock, 1000)
            {:noreply, %{state | poll: same(ref)}}
          end

          def handle_info(_msg, state), do: {:noreply, state}

          defp put_timer(state, ref), do: %{state | timer: ref}
          defp same(ref), do: ref
        end
        """)

      {:ok, data} = Disassemble.disassemble_path(bin)

      flows =
        for [_id, _func, flow, key] <- ErrorHandling.extract(data)[:timer_ref], do: {flow, key}

      assert Enum.sort(flows) == [{"stored", ":poll"}, {"stored", ":timer"}]
    end

    test "a call that drops an arming helper's ref; a field tested against nil" do
      {:ok, facts} =
        Argus.Pipeline.extract(
          [
            Argus.Test.Fixtures.TimerLoop.ThreeClauseLoop,
            Argus.Test.Fixtures.TimerLoop.BroadwayGuard
          ],
          extractors: [Argus.Extractors.ErrorHandling]
        )

      # Every call of schedule_check/1 drops the ref it returns: three in
      # handle_info/2, one in handle_call/3.
      dropped = for [_site, func, _callee] <- facts[:timer_dropped], do: func
      assert Enum.count(dropped, &(&1 =~ "handle_info/2")) == 3
      assert Enum.count(dropped, &(&1 =~ "handle_call/3")) == 1

      assert [[func, ":receive_timer"]] = facts[:field_nil_test]
      assert func =~ "receive_messages/1"
    end

    test "a nil test whose not-empty side re-arms is no guard" do
      {:ok, facts} =
        Argus.Pipeline.extract(
          [to_string(:code.which(Argus.Test.Soundness.Mailbox.NilGuardRunning))],
          extractors: [Argus.Extractors.ErrorHandling]
        )

      # set_interval re-arms on the running side of `case tref`.
      refute Map.has_key?(facts, :field_nil_test)
    end

    test "a ref read with maps:get/3 is cancelled from that field" do
      {:ok, facts} =
        Argus.Pipeline.extract([:timer_loop_domain_db],
          extractors: [Argus.Extractors.ErrorHandling]
        )

      assert [[_id, func, "field", ":check_tref", "-1"]] = facts[:timer_cancel]
      assert func =~ "maybe_cancel_timer/2"
    end

    test "a ref nothing reads before it is overwritten is discarded; one put in a term is not" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.ErrorHandlingTest.TimerDropped do
          use GenServer
          def init(s), do: {:ok, s}

          def handle_info(:dropped, state) do
            Process.send_after(self(), :dropped, 1000)
            {:noreply, state}
          end

          def handle_info(:then_call, state) do
            _ = Process.send_after(self(), :then_call, 1000)
            {:noreply, notify(state)}
          end

          def handle_info(:replied, state) do
            ref = Process.send_after(self(), :replied, 1000)
            {:noreply, {state, ref}}
          end

          def handle_info(_msg, state), do: {:noreply, state}

          defp notify(state), do: state
        end
        """)

      {:ok, data} = Disassemble.disassemble_path(bin)

      flows =
        for [_id, _func, flow, key] <- ErrorHandling.extract(data)[:timer_ref], do: {flow, key}

      # Only the ref built into a tuple may be kept: a caller or the
      # state could read it back.
      assert Enum.sort(flows) == [{"discarded", ""}, {"discarded", ""}, {"dynamic", ""}]
    end
  end

  describe "result_tested" do
    test "what a caller does with a call's result: case, boolean or returned" do
      rows = fn mod ->
        {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

        data
        |> Argus.Extractors.ErrorHandling.extract()
        |> Map.get(:result_tested, [])
        |> Enum.map(fn [_id, func, callee, how] ->
          {func |> String.split(":") |> List.last(), callee |> String.split(".") |> List.last(),
           how}
        end)
        |> Enum.sort()
      end

      alias Argus.Test.Fixtures.Hypothesized, as: H

      assert rows.(H.RpcWrapperCaller) == [
               {"delete/2", "RpcFacade:delete/2", "case"},
               {"status/2", "RpcProto:alive/2", "case"}
             ]

      assert rows.(H.RpcFacade) == [{"delete/2", "RpcProto:delete/2", "returned"}]

      # A function that compares :badrpc tests nothing for this relation;
      # a result stored in a tuple is neither tested nor returned.
      assert rows.(H.RpcWrapperCallerHandled) == [{"lookup/2", "RpcProto:lookup/2", "case"}]
    end
  end
end
