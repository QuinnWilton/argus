defmodule Argus.Extractors.OTPTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.{ApiCalls, OTP}

  describe "extract/1 — start_acked" do
    alias Argus.Test.Fixtures.InitRecv

    defp acked(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      code = data.functions |> Map.new(fn {:function, n, a, _, i} -> {"#{n}/#{a}", i} end)

      for [id, func] <- Map.get(OTP.extract(data), :start_acked, []) do
        [_, idx] = String.split(id, "#")
        name = func |> String.split(":") |> List.last()
        {name, code |> Map.fetch!(name) |> Enum.at(String.to_integer(idx)) |> elem(0)}
      end
      |> Enum.sort()
    end

    test "the calls and receives after the ack, and none before it" do
      assert acked(InitRecv.AcksThenLoops) == [{"init/1", :call_ext_last}]

      assert {"init/1", :loop_rec} in acked(InitRecv.AcksThenWaits)
      refute Enum.any?(acked(InitRecv.WaitsBeforeAck), &match?({_, :loop_rec}, &1))
    end

    test "a function with no ack has no rows" do
      assert acked(InitRecv.Waits) == []
    end
  end

  describe "extract/1 — last_send" do
    alias Argus.Test.Soundness.RacesOrder, as: O

    # The functions whose send is their last act.
    defp last_sends(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      for [_id, func] <- Map.get(OTP.extract(data), :last_send, []),
          do: func |> String.split(":") |> List.last()
    end

    test "a loader that reports as its last act" do
      for mod <- [O.Trie, :handoff_trie] do
        assert Enum.any?(last_sends(mod), &String.starts_with?(&1, "-init/1-fun-")), inspect(mod)
      end
    end

    test "a report before the work, in its middle, or before a loop is not the last act" do
      for mod <- [O.TrieReportEarly, O.TrieReportMidway, O.TrieKeepsWorking] do
        refute Enum.any?(last_sends(mod), &String.starts_with?(&1, "-init/1-fun-")), inspect(mod)
      end
    end
  end

  describe "extract/1 — behaviour detection" do
    test "detects GenServer behaviour" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MyGenServer)))

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :implements_behaviour)
      behaviours = facts[:implements_behaviour]

      assert Enum.any?(behaviours, fn [_mod, b] -> b == "GenServer" end)
    end

    test "detects no behaviour for plain module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = OTP.extract(data)

      refute Map.has_key?(facts, :implements_behaviour)
    end
  end

  describe "extract/1 — started_as" do
    defp started_as(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      data |> OTP.extract() |> Map.get(:started_as, []) |> Enum.sort()
    end

    test "a start of its own names a module that declares no behaviour" do
      assert started_as(:bless_server) == [[":bless_server", ":gen_server"]]
      assert started_as(:bless_bare_sup) == [[":bless_bare_sup", ":supervisor"]]
      assert started_as(:bless_statem) == [[":bless_statem", ":gen_statem"]]
    end

    test "a start in another module names the callback module it starts" do
      assert started_as(:bless_starter) == [[":bless_worker", ":gen_server"]]
      assert started_as(:bless_worker) == []
    end

    test "an init/1 nothing starts names nothing" do
      assert started_as(:bless_plain) == []
    end

    test "Supervisor.start_link/2 names a module, not a child list" do
      rows = started_as(Argus.Test.Fixtures.NamedStarts)
      named = "Argus.Test.Fixtures.NamedGenServer"

      assert [named, "GenServer"] in rows
      assert [named, ":gen_server"] in rows
      assert [named, "Supervisor"] in rows
      # `Supervisor.start_link([], strategy: :one_for_one, ...)` starts
      # Supervisor.Default around a child list: no callback module.
      refute Enum.any?(rows, fn [mod, _] -> mod == "[]" end)
    end
  end

  describe "extract/1 — handle_continue tags" do
    test "a tag tested after another clause's body is still a tag; the body's atoms are not" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.OTPTest.ContinueTags do
          use GenServer
          def init(s), do: {:ok, s, {:continue, :load}}

          def handle_continue(:load, s) when is_map(s) do
            case Map.get(s, :k) do
              :ok -> {:noreply, s}
              _ -> {:noreply, s, {:continue, :retry}}
            end
          end

          def handle_continue({:tick, n}, s), do: {:noreply, Map.put(s, :n, n)}
          def handle_continue(:retry, s), do: {:noreply, s}
        end
        """)

      {:ok, data} = Argus.Pipeline.Disassemble.disassemble_path(bin)

      tags =
        for [_mod, tag, _func] <- OTP.extract(data)[:handle_continue_clause], do: tag

      assert Enum.sort(tags) == [":load", ":retry"]
    end
  end

  describe "extract/1 — GenServer.call/cast detection" do
    test "detects GenServer.call in fixture" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MyGenServer)))

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :sync_call)
      calls = facts[:sync_call]
      assert calls != []
    end

    test "detects GenServer.cast in fixture" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MyGenServer)))

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :async_cast)
      casts = facts[:async_cast]
      assert casts != []
    end

    test "no GenServer calls in plain module" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.PlainModule)))

      facts = ApiCalls.extract(data)

      refute Map.has_key?(facts, :sync_call)
      refute Map.has_key?(facts, :async_cast)
    end
  end

  describe "extract/1 — supervisor management calls" do
    setup do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.SupCaller)))

      %{facts: ApiCalls.extract(data)}
    end

    test "each call is recorded with its api, op and resolved target", %{facts: facts} do
      rows = Enum.map(facts[:sup_call], fn [_id, _func, api, op, target] -> {api, op, target} end)

      assert {"Supervisor", "start_child", "Argus.Test.Fixtures.GoodSupervisor"} in rows
      assert {"DynamicSupervisor", "terminate_child", "dynamic"} in rows
      assert {"Task.Supervisor", "async_nolink", "via:MyApp.Registry"} in rows
    end

    test ":gen_statem.call is a sync call whose default timeout is infinity", %{facts: facts} do
      timeouts =
        Enum.map(facts[:sync_call_timeout], fn [func, _callee, timeout] -> {func, timeout} end)

      assert {"Argus.Test.Fixtures.SupCaller:ask/2", "-1"} in timeouts
      assert {"Argus.Test.Fixtures.SupCaller:ask/3", "0"} in timeouts
    end
  end

  describe "extract/1 — Agent sync call detection" do
    test "detects Agent.get as sync_call" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.AgentCaller)))

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :sync_call)
      calls = facts[:sync_call]
      assert length(calls) >= 3
    end
  end

  describe "extract/1 — Erlang-style :gen_server detection" do
    test "detects :gen_server.call as sync_call" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ErlangStyleCaller))
        )

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :sync_call)
    end

    test "detects :gen_server.cast as async_cast" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ErlangStyleCaller))
        )

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :async_cast)
    end
  end

  describe "extract/1 — GenServer.multi_call detection" do
    test "detects GenServer.multi_call as sync_call" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MultiCallModule)))

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :sync_call)
    end
  end

  describe "extract/1 — sync_call_timeout emission" do
    test "GenServer.call/2 emits timeout 5000" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :sync_call_timeout)
      timeouts = facts[:sync_call_timeout]

      # call_with_default uses GenServer.call/2 → 5000.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "call_with_default") and t == "5000"
             end)
    end

    test "GenServer.call/3 with integer literal emits resolved value" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = ApiCalls.extract(data)
      timeouts = facts[:sync_call_timeout]

      # call_with_explicit uses GenServer.call/3 with 10_000.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "call_with_explicit") and t == "10000"
             end)
    end

    test "GenServer.call/3 with :infinity emits -1" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = ApiCalls.extract(data)
      timeouts = facts[:sync_call_timeout]

      # call_with_infinity uses GenServer.call/3 with :infinity.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "call_with_infinity") and t == "-1"
             end)
    end

    test ":gen_server.call/3 with integer emits resolved value" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.ExplicitTimeoutCaller))
        )

      facts = ApiCalls.extract(data)
      timeouts = facts[:sync_call_timeout]

      # erlang_call_with_timeout uses :gen_server.call/3 with 15_000.
      assert Enum.any?(timeouts, fn [func, _callee, t] ->
               String.contains?(func, "erlang_call_with_timeout") and t == "15000"
             end)
    end

    test "GenServer.multi_call emits -1 (infinity)" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.MultiCallModule)))

      facts = ApiCalls.extract(data)

      assert Map.has_key?(facts, :sync_call_timeout)
      timeouts = facts[:sync_call_timeout]
      assert Enum.any?(timeouts, fn [_func, _callee, t] -> t == "-1" end)
    end
  end

  describe "extract/1 — link/monitor detection" do
    test "detects Process.link as process_link" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.LinkMonitorModule))
        )

      facts = OTP.extract(data)

      assert Map.has_key?(facts, :process_link)
      links = facts[:process_link]
      assert length(links) >= 2
    end
  end

  describe "extract/1 — :via tuple resolution" do
    test "still emits sync_call with a synthetic via:<RegistryInstance> callee tag" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(to_string(:code.which(Argus.Test.Fixtures.ViaTupleCaller)))

      facts = ApiCalls.extract(data)

      sync_calls = facts[:sync_call]

      assert Enum.any?(sync_calls, fn [_caller, callee] ->
               callee == "via:MyApp.Registry"
             end)
    end
  end

  describe "extract/1 — what a callback's return asks of its loop" do
    alias Argus.Test.Soundness.Runs

    defp asks(mod, rel) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))

      for row <- Map.get(OTP.extract(data), rel, []) do
        [_id, func | rest] = row
        [func |> String.split(":") |> List.last() | rest]
      end
      |> Enum.uniq()
      |> Enum.sort()
    end

    test "a continue from init/1 and from a handler's clause, by their tags" do
      assert asks(Runs.ContinueAgain, :continue_return) == [
               ["handle_info/2", ":reset", ":setup"],
               ["init/1", "*", ":setup"]
             ]
    end

    test "a continue a helper returns, and one whose term the return does not spell" do
      assert ["reload/1", "*", ":setup"] in asks(Runs.ContinueFromHelper, :continue_return)
      assert ["handle_info/2", ":next", "*"] in asks(Runs.ContinueAny, :continue_return)
    end

    test "a continue's tuple term is told by its first element" do
      assert asks(Runs.LoopReturns, :continue_return) == [["init/1", "*", ":load"]]
    end

    test "a timeout, spelled or not; :infinity, :hibernate and a continue are none" do
      assert asks(Runs.LoopReturns, :timeout_return) == [
               ["handle_call/3", ":soon"],
               ["handle_cast/2", ":wait"]
             ]

      assert asks(Runs.TimeoutAgain, :timeout_return) == [
               ["handle_cast/2", ":poke"],
               ["init/1", "*"]
             ]

      assert asks(Runs.TimeoutFromHelper, :timeout_return) == [
               ["init/1", "*"],
               ["rearm/1", "*"]
             ]
    end
  end

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.MyGenServer],
                 extractors: [OTP, ApiCalls]
               )

      assert Map.has_key?(facts, :implements_behaviour)
      assert Map.has_key?(facts, :sync_call)
    end
  end
end
