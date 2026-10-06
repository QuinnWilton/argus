defmodule Argus.Soundness.StateMachineTest do
  @moduledoc """
  state_machine bugs a suppression once silenced: each program is solved
  alone and must keep its finding at the severity the rule gave it
  before the suppression (`Argus.Test.Soundness`).
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.StateMachine, as: S

  describe "review 2, item 27 (6aff4d81)" do
    test "a dead state re-entered only through its own helper" do
      assert {:warning, "Unreachable gen_statem state", {S.SelfHelperStatem, :legacy, 3}} in fired(
               [S.SelfHelperStatem],
               :state_machine
             )
    end

    test "a terminal state that hands every event to another module's handler" do
      assert {:info, "Terminal gen_statem state that never stops",
              {S.RemoteTerminalStatem, :closed, 3}} in fired(
               [S.RemoteTerminalStatem, S.RemoteTerminalCommon],
               :state_machine
             )
    end
  end
end
