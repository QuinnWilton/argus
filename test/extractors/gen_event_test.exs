defmodule Argus.Extractors.GenEventTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.{ApiCalls, OTP}

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1 — behaviour detection" do
    test "records implements_behaviour for :gen_event handlers" do
      facts = OTP.extract(disassemble(Argus.Test.Fixtures.MyEventHandler))

      assert Map.has_key?(facts, :implements_behaviour)

      assert Enum.any?(facts[:implements_behaviour], fn [mod, behaviour] ->
               mod == "Argus.Test.Fixtures.MyEventHandler" and behaviour == ":gen_event"
             end)
    end

    test "skips modules that don't implement :gen_event" do
      facts = OTP.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      refute Map.has_key?(facts, :implements_behaviour)
    end
  end

  describe "extract/1 — sync_call coverage" do
    test "treats :gen_event.sync_notify as a sync_call" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GenEventEmitter))

      assert Map.has_key?(facts, :sync_call)

      assert Enum.any?(facts[:sync_call], fn [caller, callee] ->
               String.contains?(caller, "sync_notify_event") and callee == "MyEventManager"
             end)
    end

    test "treats :gen_event.call/3 and /4 as sync_call" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GenEventEmitter))

      callers =
        facts[:sync_call]
        |> Enum.map(fn [caller, _] -> caller end)

      assert Enum.any?(callers, &String.contains?(&1, "call_handler/0"))
      assert Enum.any?(callers, &String.contains?(&1, "call_handler_with_timeout"))
    end
  end

  describe "extract/1 — async_cast coverage" do
    test "treats :gen_event.notify as an async_cast" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GenEventEmitter))

      assert Map.has_key?(facts, :async_cast)

      assert Enum.any?(facts[:async_cast], fn [caller, callee] ->
               String.contains?(caller, "notify_event") and callee == "MyEventManager"
             end)
    end
  end
end
