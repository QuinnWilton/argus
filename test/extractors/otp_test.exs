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

      assert OTP.extract(data)[:implements_behaviour] == [
               ["Argus.Test.Fixtures.MyGenServer", "GenServer"]
             ]
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

  describe "extract/1 — process calls" do
    alias Argus.Test.Fixtures, as: F

    @process_call_relations [
      :sync_call,
      :sync_call_timeout,
      :sync_call_site,
      :async_cast,
      :async_cast_site,
      :sup_call
    ]

    # A module's process calls, one row per call: [func, "call", target,
    # timeout], [func, "cast", target] or [func, api, op, target]. The
    # relations that restate a call — sync_call is sync_call_timeout less
    # its timeout, a site row is its call's row behind an instruction id —
    # are checked against it here, so the table states each call once.
    defp process_calls(mod) do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
      facts = ApiCalls.extract(data)
      rows = &(facts |> Map.get(&1, []) |> Enum.sort())

      assert Map.keys(facts) -- @process_call_relations == []

      assert rows.(:sync_call) ==
               Enum.sort(for [f, t, _ms] <- rows.(:sync_call_timeout), do: [f, t])

      assert unsited(rows.(:sync_call_site)) == rows.(:sync_call_timeout)
      assert unsited(rows.(:async_cast_site)) == rows.(:async_cast)

      Enum.sort(
        for([f, t, ms] <- rows.(:sync_call_timeout), do: [short(f), "call", t, ms]) ++
          for([f, t] <- rows.(:async_cast), do: [short(f), "cast", t]) ++
          for([f, api, op, t] <- unsited(rows.(:sup_call)), do: [short(f), api, op, t])
      )
    end

    defp unsited(rows) do
      rows
      |> Enum.map(fn [id, func | rest] ->
        assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
        [func | rest]
      end)
      |> Enum.sort()
    end

    defp short(func), do: func |> String.split(":") |> List.last()

    test "each call with its target and its timeout" do
      for {mod, calls} <- [
            {F.MyGenServer,
             [["get_value/1", "call", "dynamic", "5000"], ["set_value/2", "cast", "dynamic"]]},
            # An Agent call is a GenServer.call with the same default.
            {F.AgentCaller,
             [
               ["get_and_update/1", "call", "dynamic", "5000"],
               ["get_state/1", "call", "dynamic", "5000"],
               ["update_state/2", "call", "dynamic", "5000"]
             ]},
            {F.ErlangStyleCaller,
             [["call_server/1", "call", "dynamic", "5000"], ["cast_server/1", "cast", "dynamic"]]},
            # multi_call/2 has no timeout argument and waits forever.
            {F.MultiCallModule, [["multi_call_nodes/2", "call", "dynamic", "-1"]]},
            # A literal timeout is read in milliseconds, :infinity as -1.
            {F.ExplicitTimeoutCaller,
             [
               ["call_with_default/1", "call", "dynamic", "5000"],
               ["call_with_explicit/1", "call", "dynamic", "10000"],
               ["call_with_infinity/1", "call", "dynamic", "-1"],
               ["erlang_call_with_timeout/1", "call", "dynamic", "15000"]
             ]},
            # A literal {:via, Registry, {reg, key}} names the registry.
            {F.ViaTupleCaller,
             [
               ["cast_to/2", "cast", "via:MyApp.Registry"],
               ["get/1", "call", "via:MyApp.Registry", "5000"]
             ]},
            # A supervisor call is no GenServer call. :gen_statem.call/2
            # waits forever; /3's timeout is a parameter, unread ("0").
            {F.SupCaller,
             [
               ["add/1", "Supervisor", "start_child", "Argus.Test.Fixtures.GoodSupervisor"],
               ["ask/2", "call", "dynamic", "-1"],
               ["ask/3", "call", "dynamic", "0"],
               ["drop/2", "DynamicSupervisor", "terminate_child", "dynamic"],
               ["run/1", "Task.Supervisor", "async_nolink", "via:MyApp.Registry"]
             ]}
          ] do
        assert {mod, process_calls(mod)} == {mod, calls}
      end
    end
  end

  describe "extract/1 — link detection" do
    test "Process.link and :erlang.link are links; monitors are not" do
      {:ok, data} =
        BeamSpy.BeamFile.disassemble(
          to_string(:code.which(Argus.Test.Fixtures.LinkMonitorModule))
        )

      mod = "Argus.Test.Fixtures.LinkMonitorModule"
      assert OTP.extract(data)[:process_link] == [[mod, "dynamic"], [mod, "dynamic"]]
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
end
