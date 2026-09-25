defmodule Argus.Soundness.UnsafeInputChildrenTest do
  @moduledoc """
  unsafe_input bugs a suppression once silenced, and their adversarial
  neighbours: each program is solved alone and must keep its finding at
  the severity the rule gave it before the suppression
  (`Argus.Test.Soundness`).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.UnsafeInput.Children, as: C

  @unbounded "Dynamic supervisor starts children without limit, on request"

  describe "a child its request waits out is the one whose :DOWN every path takes (review 2, item 5)" do
    for {live, sup} <- [
          {C.ReplyLive, C.ReplySup},
          {C.TimedLive, C.TimedSup},
          {C.AnyDownLive, C.AnyDownSup},
          {C.TwiceLive, C.TwiceSup}
        ] do
      @live live
      @sup sup
      test "#{inspect(live)} leaves a child alive on some path" do
        assert {:error, @unbounded, {@live, :handle_event, 3}} in fired(
                 [@live, @sup, C.Worker],
                 :unsafe_input
               )
      end
    end
  end
end
