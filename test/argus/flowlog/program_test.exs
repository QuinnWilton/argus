defmodule Argus.FlowLog.ProgramTest do
  @moduledoc """
  Which profile a program's engine is built with
  (`Argus.FlowLog.Program.profile/1`): argus's own programs as they
  ship, and any other as `ARGUS_FLOWLOG_BUILD_PROFILE` asks.

  Each test runs in a peer (`Argus.Test.Peer`): the variable is VM-wide.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.FlowLog.Program
  alias Argus.Test.Peer

  setup do
    %{peer: Peer.start!()}
  end

  test "argus's own programs build as they ship, whatever the profile asks",
       %{peer: peer} do
    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_BUILD_PROFILE", "quick")
      assert Program.profile(Argus.Dl.path("stage0.dl")) == :release
      assert Program.profile("/elsewhere/rules.dl") == :quick

      System.put_env("ARGUS_FLOWLOG_BUILD_PROFILE", "fast")

      assert_raise ArgumentError, ~r/ARGUS_FLOWLOG_BUILD_PROFILE is "fast"/, fn ->
        Program.profile("/elsewhere/rules.dl")
      end
    end)
  end
end
