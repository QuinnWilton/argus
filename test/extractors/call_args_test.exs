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

  defp forwards_for(facts, callee_pattern) do
    (facts[:call_arg_forward] || [])
    |> Enum.filter(fn [_caller, callee, _pos, _fwd] ->
      String.contains?(callee, callee_pattern)
    end)
  end

  # Rows from both relations — together they are what call_arg alone used
  # to be, so coverage questions ("was this position recorded at all?")
  # have to ask both.
  defp all_args_for(facts, callee_pattern) do
    ((facts[:call_arg] || []) ++ (facts[:call_arg_forward] || []))
    |> Enum.filter(fn [_caller, callee, _pos, _] ->
      String.contains?(callee, callee_pattern)
    end)
  end

  defp all_arg_positions(facts) do
    ((facts[:call_arg] || []) ++ (facts[:call_arg_forward] || []))
    |> Enum.map(fn [_, _, pos, _] -> String.to_integer(pos) end)
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
    # Forwardings go to call_arg_forward with the forwarded position as a
    # real number column, not into call_arg's value as the string "arg:N".
    # The string form made Datalog decode it with the PARTIAL functor
    # to_number, which Souffle was free to schedule ahead of its guard.

    test "records parameter 0 forwarded to GenServer.call" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      fwd =
        forwards_for(facts, "GenServer:call/2")
        |> Enum.filter(fn [caller, _, _, _] -> caller =~ "call_server/1" end)
        |> Enum.find(fn [_, _, pos, _] -> pos == "0" end)

      assert fwd
      [_, _, _, fwd_pos] = fwd
      assert fwd_pos == "0"
    end

    test "records parameter 1 forwarded to :ets.lookup arg 0" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      fwd =
        forwards_for(facts, ":ets:lookup/2")
        |> Enum.filter(fn [caller, _, _, _] -> caller =~ "read_table/2" end)
        |> Enum.find(fn [_, _, pos, _] -> pos == "0" end)

      assert fwd
      [_, _, _, fwd_pos] = fwd
      assert fwd_pos == "1"
    end

    test "records both forwarded arguments, each with its own source position" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      pairs =
        forwards_for(facts, "GenServer:call/2")
        |> Enum.filter(fn [caller, _, _, _] -> caller =~ "forward_both/2" end)
        |> Enum.map(fn [_, _, pos, fwd] -> {pos, fwd} end)

      assert {"0", "0"} in pairs
      assert {"1", "1"} in pairs
    end

    test "a forwarded argument produces no call_arg row" do
      # The split has to be exclusive: if a forwarding also landed in
      # call_arg, resolved_arg's base case would treat the marker as a
      # literal value and propagate garbage.
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      literals =
        call_args_for(facts, "GenServer:call/2")
        |> Enum.filter(fn [caller, _, pos, _] -> caller =~ "call_server/1" and pos == "0" end)

      assert literals == []
    end

    test "no fact anywhere still carries the old arg:N encoding" do
      facts = extract(Argus.Test.Fixtures.CallArgsForwarder)

      values = Enum.map(facts[:call_arg] || [], fn [_, _, _, val] -> val end)

      refute Enum.any?(values, &String.starts_with?(&1, "arg:")),
             "call_arg still encodes forwarding in a string"
    end
  end

  describe "arity cap" do
    test "only emits first 4 arguments for high-arity calls" do
      facts = extract(Argus.Test.Fixtures.CallArgsMultiArity)

      # Coverage question, so it spans both relations: one of these two
      # arguments is a forwarded parameter and lives in call_arg_forward.
      positions =
        facts
        |> all_args_for(":erlang:send/2")
        |> Enum.map(fn [_, _, pos, _] -> pos end)
        |> Enum.sort()

      # :erlang.send/2 has arity 2, so both args should be emitted.
      assert positions == ["0", "1"]
    end

    test "caps at 4 arguments for the caller's own calls" do
      facts = extract(Argus.Test.Fixtures.CallArgsMultiArity)

      # many_args/6 body calls :erlang.send/2 — only 2 args.
      # But let's verify no arg_pos > 3 appears anywhere in the facts.
      assert Enum.all?(all_arg_positions(facts), &(&1 < 4))
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
    test "a parameter passed straight through is a forwarding, not a value" do
      facts = extract(Argus.Test.Fixtures.CallArgsLiteral)

      # lookup/1 passes `key` (parameter 0) as arg 1 to :ets.lookup. Before
      # the split this test hedged — `value in ["arg:0", "dynamic"]` — because
      # call_arg could not say which it was without string-matching. Now the
      # relation the row lands in answers it.
      fwd =
        facts
        |> forwards_for(":ets:lookup/2")
        |> Enum.find(fn [_, _, pos, _] -> pos == "1" end)

      assert fwd, "arg 1 of :ets.lookup/2 was not recorded as a forwarding"
      assert [_, _, "1", "0"] = fwd
    end

    test "emits 'dynamic' when resolution genuinely fails" do
      facts = extract(Argus.Test.Fixtures.CallArgsMultiArity)

      values = Enum.map(facts[:call_arg] || [], fn [_, _, _, val] -> val end)

      assert "dynamic" in values,
             "no unresolvable argument in the fixture; this test proves nothing"
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
