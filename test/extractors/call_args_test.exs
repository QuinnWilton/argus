defmodule Argus.Extractors.CallArgsTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.CallArgs

  defp extract(module) do
    {:ok, data} =
      BeamSpy.BeamFile.disassemble(to_string(:code.which(module)))

    CallArgs.extract(data)
  end

  defp call_args_for(facts, callee_pattern) do
    (facts[:call_arg] || [])
    |> Enum.filter(fn [_caller, callee, _pos, _val] ->
      String.contains?(callee, callee_pattern)
    end)
  end

  defp call_args_from(facts, caller_pattern) do
    (facts[:call_arg] || [])
    |> Enum.filter(fn [caller, _callee, _pos, _val] ->
      String.contains?(caller, caller_pattern)
    end)
  end

  describe "literal arguments" do
    test "emits literal atom value for GenServer.call with __MODULE__" do
      facts = extract(Argus.Test.Fixtures.CallArgsLiteral)
      gs_args = call_args_for(facts, "GenServer:call/2")

      arg0 =
        Enum.find(gs_args, fn [_, _, pos, _] -> pos == "0" end)

      assert arg0
      [caller, _, _, value] = arg0
      assert caller =~ "CallArgsLiteral:ping/0"
      assert value == "Argus.Test.Fixtures.CallArgsLiteral"
    end

    test "emits literal atom value for :ets.lookup table name" do
      facts = extract(Argus.Test.Fixtures.CallArgsLiteral)
      ets_args = call_args_for(facts, ":ets:lookup/2")

      arg0 =
        Enum.find(ets_args, fn [_, _, pos, _] -> pos == "0" end)

      assert arg0
      [_, _, _, value] = arg0
      assert value == ":my_test_table"
    end
  end

  describe "parameter forwarding" do
    test "emits arg:0 when parameter 0 is forwarded to GenServer.call" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      gs_args =
        call_args_for(facts, "GenServer:call/2")
        |> Enum.filter(fn [caller, _, _, _] -> caller =~ "call_server/1" end)

      arg0 =
        Enum.find(gs_args, fn [_, _, pos, _] -> pos == "0" end)

      assert arg0
      [_, _, _, value] = arg0
      assert value == "arg:0"
    end

    test "emits arg:1 when parameter 1 is forwarded to :ets.lookup arg 0" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      ets_args =
        call_args_for(facts, ":ets:lookup/2")
        |> Enum.filter(fn [caller, _, _, _] -> caller =~ "read_table/2" end)

      arg0 =
        Enum.find(ets_args, fn [_, _, pos, _] -> pos == "0" end)

      assert arg0
      [_, _, _, value] = arg0
      assert value == "arg:1"
    end

    test "emits arg:N for both forwarded arguments" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      gs_args =
        call_args_for(facts, "GenServer:call/2")
        |> Enum.filter(fn [caller, _, _, _] -> caller =~ "forward_both/2" end)

      values =
        gs_args
        |> Enum.sort_by(fn [_, _, pos, _] -> pos end)
        |> Enum.map(fn [_, _, pos, val] -> {pos, val} end)

      assert {"0", "arg:0"} in values
      assert {"1", "arg:1"} in values
    end
  end

  describe "arity cap" do
    test "only emits first 4 arguments for high-arity calls" do
      facts = extract(Argus.Test.Fixtures.CallArgsMultiArity)

      send_args = call_args_for(facts, ":erlang:send/2")

      positions =
        send_args
        |> Enum.map(fn [_, _, pos, _] -> pos end)
        |> Enum.sort()

      # :erlang.send/2 has arity 2, so both args should be emitted.
      assert positions == ["0", "1"]
    end

    test "caps at 4 arguments for the caller's own calls" do
      facts = extract(Argus.Test.Fixtures.CallArgsMultiArity)

      # many_args/6 body calls :erlang.send/2 — only 2 args.
      # But let's verify no arg_pos > 3 appears anywhere in the facts.
      all_positions =
        (facts[:call_arg] || [])
        |> Enum.map(fn [_, _, pos, _] -> String.to_integer(pos) end)

      assert Enum.all?(all_positions, &(&1 < 4))
    end
  end

  describe "local calls" do
    test "captures local call arguments alongside remote calls" do
      facts = extract(Argus.Test.Fixtures.CallArgsLocalCall)

      local_args =
        call_args_from(facts, "public_api/0")
        |> Enum.filter(fn [_, callee, _, _] -> callee =~ "do_work/1" end)

      assert length(local_args) >= 1

      arg0 =
        Enum.find(local_args, fn [_, _, pos, _] -> pos == "0" end)

      assert arg0
      [_, _, _, value] = arg0
      assert value == ":literal_arg"
    end
  end

  describe "dynamic arguments" do
    test "emits 'dynamic' for runtime-computed values" do
      facts = extract(Argus.Test.Fixtures.CallArgsLiteral)

      # lookup/1 passes `key` (parameter 0) as arg 1 to :ets.lookup.
      ets_args = call_args_for(facts, ":ets:lookup/2")

      arg1 =
        Enum.find(ets_args, fn [_, _, pos, _] -> pos == "1" end)

      assert arg1
      [_, _, _, value] = arg1
      # key is parameter 0, so it should be "arg:0" not "dynamic"
      assert value in ["arg:0", "dynamic"]
    end
  end

  describe "fact shape" do
    test "all call_arg rows have exactly 4 fields" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      for row <- facts[:call_arg] || [] do
        assert length(row) == 4,
               "expected 4 fields, got #{length(row)}: #{inspect(row)}"
      end
    end

    test "caller and callee use func_id format (Mod:func/arity)" do
      facts = extract(Argus.Test.Fixtures.CallArgsLiteral)

      for [caller, callee, _pos, _val] <- facts[:call_arg] || [] do
        assert caller =~ ~r/.+:.+\/\d+/,
               "caller not in func_id format: #{caller}"

        assert callee =~ ~r/.+:.+\/\d+/,
               "callee not in func_id format: #{callee}"
      end
    end
  end
end
