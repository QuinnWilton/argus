defmodule Argus.Soundness.ShutdownTest do
  @moduledoc """
  shutdown bugs a suppression once silenced, and their adversarial
  neighbours: each program is solved alone and must keep its finding at
  the severity the rule gave it before the suppression
  (`Argus.Test.Soundness`).
  """
  use ExUnit.Case, async: true

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Test.Memo
  alias Argus.Test.Rows
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

  describe "what runs when a supervisor stops the process" do
    # A supervisor's stop passes terminate/2 the bare :shutdown; the
    # reason is followed through the helpers and client APIs it is handed
    # to (shutdown.dl, stop_path and api_waits_holding). The rows name
    # the caller, the kind and the function that waits.
    alias Argus.Test.Soundness.Shutdown.Reason, as: R

    @reason_set [
      R.Sup,
      R.Directory,
      R.ShutdownClause,
      R.NotShutdown,
      R.NotShutdownExact,
      R.ShutdownTuple,
      R.NormalThenAny,
      R.HelperChooses,
      R.HelperShutdownClause,
      R.HelperOtherValue,
      R.Relay,
      R.RelayShutdownClause,
      R.ApiChooses,
      R.ApiShutdownClause
    ]

    @mnesia_set [:reason_kernel_sup, :reason_monitor, :reason_controller, :reason_reporter]

    # {caller, kind, the function that waits} of each terminate/2 row.
    defp sibling_calls(modules) do
      {:ok, results} = Memo.analyze(modules, :shutdown)

      for [mod, kind, via] <-
            Rows.where(results, :shutdown, "teardown_touches_sibling",
              phase: "terminate",
              drop: [:sibling, :phase, :sup, :handler, :site, :sup_site]
            ),
          uniq: true,
          do: {short(mod), kind, via |> String.split(":") |> Enum.at(-1)}
    end

    defp short(":" <> mod), do: mod
    defp short(mod), do: mod |> String.split(".") |> List.last()

    test "a clause that takes :shutdown, and a catch-all after :normal's, fire" do
      calls = sibling_calls(@reason_set)

      assert {"ShutdownClause", "call", "terminate/2"} in calls
      assert {"NormalThenAny", "call", "terminate/2"} in calls
    end

    test "a helper's clause for :shutdown fires, directly and through a relay" do
      calls = sibling_calls(@reason_set)

      assert {"HelperShutdownClause", "call", "leave/1"} in calls
      assert {"RelayShutdownClause", "call", "leave/1"} in calls
    end

    test "a client API whose clause for :shutdown waits fires" do
      assert {"ApiShutdownClause", "call", "terminate/2"} in sibling_calls(@reason_set)
    end

    test "a helper handed another value on the stop runs its other clauses" do
      assert {"HelperOtherValue", "call", "leave/1"} in sibling_calls(@reason_set)
    end

    test "a clause guarded against :shutdown, or for {:shutdown, _}, and a helper's or API's clause for other reasons are quiet" do
      quiet = ~w(NotShutdown NotShutdownExact ShutdownTuple HelperChooses Relay ApiChooses)
      assert for({mod, _, _} <- sibling_calls(@reason_set), mod in quiet, do: mod) == []
    end

    test "mnesia's shape: an API that waits only for a crash, under a one_for_all restart" do
      calls = sibling_calls(@mnesia_set)

      assert {"reason_reporter", "call_restart", "terminate/2"} in calls
      refute Enum.any?(calls, &match?({"reason_controller", _, _}, &1))
    end
  end
end
