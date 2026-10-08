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

      assert facts[:implements_behaviour] == [
               ["Argus.Test.Fixtures.MyEventHandler", ":gen_event"]
             ]
    end
  end

  describe "extract/1 — calls to a manager" do
    test "sync_notify and call/3,4 are sync calls, notify a cast; add_handler is neither" do
      facts = ApiCalls.extract(disassemble(Argus.Test.Fixtures.GenEventEmitter))
      emitter = "Argus.Test.Fixtures.GenEventEmitter"

      assert Enum.sort(facts[:sync_call]) == [
               ["#{emitter}:call_handler/0", "MyEventManager"],
               ["#{emitter}:call_handler_with_timeout/0", "MyEventManager"],
               ["#{emitter}:sync_notify_event/0", "MyEventManager"]
             ]

      assert facts[:async_cast] == [["#{emitter}:notify_event/0", "MyEventManager"]]
    end
  end
end
