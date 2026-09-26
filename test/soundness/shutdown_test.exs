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

  # The exclusion census's shutdown hole (docs/design/exclusions.md): a
  # demonitor anywhere in the module excused every kill of a monitored
  # process. The kill is tied to the monitored process (points-to), and
  # only a demonitor on the kill's own way releases it.
  describe "census hole: a kill of a monitored process" do
    alias Argus.Test.Soundness.Census.Shutdown, as: C

    @census [
      C.Job,
      C.Runner,
      C.Stopper,
      C.HelperKiller,
      C.ReleasingRunner,
      C.Registry,
      C.UnwatchedKiller
    ]

    @kills "Server terminates a process it still monitors"

    for mfa <- [
          {C.Runner, :handle_info, 2},
          {C.Stopper, :handle_info, 2},
          {C.HelperKiller, :kill_job, 1}
        ] do
      test "#{inspect(mfa)}: an unrelated demonitor releases nothing the kill brings" do
        assert {:info, @kills, unquote(Macro.escape(mfa))} in fired(@census, :shutdown)
      end
    end

    test "a demonitor on the kill's way, and a kill of an unmonitored process, are quiet" do
      found = fired(@census, :shutdown)

      for mod <- [C.ReleasingRunner, C.UnwatchedKiller] do
        refute Enum.any?(found, &match?({_, @kills, {^mod, _, _}}, &1)), inspect(mod)
      end
    end
  end
end
