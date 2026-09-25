defmodule Argus.Soundness.ShutdownTest do
  @moduledoc """
  shutdown bugs a suppression once silenced, and their adversarial
  neighbours: each program is solved alone and must keep its finding at
  the severity the rule gave it before the suppression
  (`Argus.Test.Soundness`).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Soundness.Shutdown, as: S

  @no_handler "trap_exit without an :EXIT handler"

  describe "a trapped exit nothing takes (review 2, item 9)" do
    test "a spawn_link'ed loop whose receive has no :EXIT clause" do
      assert {:warning, @no_handler, {S.TrapLoopFn, :run, 1}} in fired([S.TrapLoopFn], :shutdown)
    end

    test "a server under an unlisted wrapper with no handle_info/2" do
      assert {:warning, @no_handler, {:soundness_gs2trap, :init, 1}} in fired(
               [:soundness_gs2trap],
               :shutdown
             )
    end

    test "a trap in a setup helper before the spawned fun's loop" do
      assert {:warning, @no_handler, {S.SetupThenLoop, :setup, 1}} in fired(
               [S.SetupThenLoop],
               :shutdown
             )
    end

    test "a proc_lib process under a behaviour argus does not know" do
      assert {:warning, @no_handler, {S.ProcLibLoop, :init, 1}} in fired(
               [S.ProcLibLoop, S.Protocol],
               :shutdown
             )
    end

    test "a loop that takes the exit, or any message, is quiet" do
      assert fired([S.ExitClauseLoop, S.CatchAllLoop], :shutdown) == []
    end
  end
end
