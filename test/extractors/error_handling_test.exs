defmodule Argus.Extractors.ErrorHandlingTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ErrorHandling
  alias Argus.Pipeline.Disassemble

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — bare rescue" do
    test "detects bare catch that swallows all exceptions" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.BareRescue))

      assert Map.has_key?(facts, :bare_rescue)
      rows = facts[:bare_rescue]
      assert rows != []
    end

    test "does not flag rescue with exception class filtering" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.FilteredRescue))

      bare = Map.get(facts, :bare_rescue, [])
      assert bare == []
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

  describe "extract/1 — apply_param and the apply writer" do
    alias Argus.Test.Fixtures.LateMessage

    defp applies(mod) do
      facts = ErrorHandling.extract(disassemble(mod))
      name = &(&1 |> String.split(":") |> List.last())

      {for([_id, func, pos] <- Map.get(facts, :apply_param, []), do: {name.(func), pos}),
       for([_id, func, "apply"] <- Map.get(facts, :mailbox_writer, []), do: name.(func))}
    end

    test "a call through a parameter names it; through the state it is an apply" do
      assert applies(LateMessage.HandsClosure) == {[{"with_retry/1", "0"}], []}
      assert applies(LateMessage.RunsSentFun) == {[{"run/1", "0"}], []}
      assert applies(LateMessage.Warmer) == {[], ["execute/1"]}
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

    test "with the Line table, the span ends on the catch's highest line" do
      beam = to_string(:code.which(Argus.Test.Fixtures.CatchShapes.NoprocLogged))

      {:ok, facts} =
        Argus.Pipeline.extract([beam], format: :typed, extractors: [ErrorHandling])

      lines = Map.new(facts.line_info, &{{&1.id.func, &1.id.arity, &1.id.idx}, &1.line})

      line_of = fn
        %Argus.InstrId{} = i ->
          lines[{i.func, i.arity, i.idx}]

        id ->
          {:ok, i} = Argus.InstrId.parse(id)
          lines[{i.func, i.arity, i.idx}]
      end

      assert [%{call: call, guard_end: guard_end}] = facts.try_call
      # The catch's last body line is three below the call in the fixture.
      # (A catch whose body is a literal gets no line of its own from the
      # compiler; the span then stays on the call.)
      assert line_of.(guard_end) == line_of.(call) + 3
    end

    test "the span stops at the catch when the try is not in tail position" do
      beam = to_string(:code.which(Argus.Test.Fixtures.CatchShapes.NoprocThenMore))

      {:ok, facts} =
        Argus.Pipeline.extract([beam], format: :typed, extractors: [ErrorHandling])

      lines = Map.new(facts.line_info, &{{&1.id.func, &1.id.arity, &1.id.idx}, &1.line})

      line_of = fn
        %Argus.InstrId{} = i ->
          lines[{i.func, i.arity, i.idx}]

        id ->
          {:ok, i} = Argus.InstrId.parse(id)
          lines[{i.func, i.arity, i.idx}]
      end

      assert [%{call: call, guard_end: guard_end}] = facts.try_call
      # The catch's last marked line (its send/2; the literal after it has
      # no marker), not the send/2 seven lines further on.
      assert line_of.(guard_end) == line_of.(call) + 3

      # The handler's own row ends its span at the same place.
      assert [%{id: try_id}] = facts.try_call
      assert [%{span_end: ^guard_end}] = Enum.filter(facts.catch_class, &(&1.id == try_id))
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

  describe "extract/1 — try_covers" do
    alias Argus.Extractor.Helpers
    alias Argus.Test.Fixtures.SiblingGuard, as: G

    # {try index, callee, kind} for every call a try in `name/arity` covers.
    defp covered(mod, name, arity) do
      data = disassemble(mod)
      instrs = Helpers.find_function(data.functions, name, arity)
      func = Argus.Pipeline.Normalize.func_id(mod, name, arity)

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
    test "detects Process.flag(:trap_exit, true)" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.TrapExitModule))

      assert Map.has_key?(facts, :trap_exit)
      rows = facts[:trap_exit]
      assert rows != []

      mods = Enum.map(rows, fn [_, mod] -> mod end)
      assert Enum.any?(mods, &String.contains?(&1, "TrapExitModule"))
    end
  end

  describe "extract/1 — exit calls" do
    test "detects Process.exit/2" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ExitCaller))

      assert Map.has_key?(facts, :exit_call)
      rows = facts[:exit_call]
      assert rows != []
    end

    test "detects :erlang.exit/1" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.ExitCaller))

      rows = facts[:exit_call]

      assert Enum.any?(rows, fn [_, func, _] ->
               String.contains?(func, "exit_self")
             end)
    end
  end

  describe "extract/1 — ignored error results" do
    test "detects ignored GenServer.start_link result" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.IgnoredResultModule))

      ignored = Map.get(facts, :ignored_error_result, [])

      assert Enum.any?(ignored, fn [_, func, callee] ->
               String.contains?(func, "ignored_start") and
                 String.contains?(callee, "start_link")
             end)
    end

    test "does not flag checked GenServer.start_link result" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.IgnoredResultModule))

      ignored = Map.get(facts, :ignored_error_result, [])

      refute Enum.any?(ignored, fn [_, func, _] ->
               String.contains?(func, "checked_start")
             end)
    end
  end

  describe "extract/1 — clean module" do
    test "returns empty for plain module" do
      facts = ErrorHandling.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.TrapExitModule],
                 extractors: [ErrorHandling]
               )

      assert Map.has_key?(facts, :trap_exit)
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
