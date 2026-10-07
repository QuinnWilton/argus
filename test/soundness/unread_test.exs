defmodule Argus.Soundness.UnreadTest do
  @moduledoc """
  An unread value is unknown, never the default (issue #4): only an
  absent key takes OTP's or the library's default, and a field a
  child_spec/1 reads off its argument is the start's option, or the
  default where the start's argument does not hold it. Each field and
  option has the shapes that must keep their finding (positive evidence
  of the value the finding needs) beside the quiet ones an unread value
  leaves unknown (test/fixtures/soundness/unread_fixture.ex). The restart
  itself, with the issue's repro, is test/analyses/shutdown_supervision_test.exs's.
  """
  use ExUnit.Case, async: true
  @moduletag :flowlog

  import Argus.Test.Soundness, only: [fired: 2]

  alias Argus.Pipeline
  alias Argus.Test.Memo
  alias Argus.Test.Soundness.Unread, as: U

  defp rows(modules, analysis, relation) do
    {:ok, results} = Memo.analyze(modules, analysis)
    Map.get(results, relation, [])
  end

  defp short(name), do: name |> String.split(".") |> List.last()

  describe "a child spec's type, read off its argument" do
    test "a supervisor is registered as a worker where the start's argument holds no type, or :worker" do
      starts =
        for [child, _sup, via] <-
              rows(
                [U.TypedSup, U.UnreadTypeSup, U.TypedStarts, U.ListTyped],
                :structure,
                "own_spec_registered_as_worker"
              ),
            do: {short(child), via |> String.split(":") |> List.last()}

      # The default, the argument's own :worker, and a child list's
      # default; not the argument's :supervisor, an argument the extractor
      # cannot read, or a type it cannot read (`opts[:type] || :worker`).
      assert Enum.sort(starts) == [
               {"TypedSup", ""},
               {"TypedSup", "as_worker/0"},
               {"TypedSup", "by_default/0"}
             ]
    end
  end

  describe "a computed restart in OTP's tuple form" do
    test "is unknown, and no excuse for a table that dies with its owner" do
      found =
        for {_, "ETS table dies with its owner", {mod, _, _}} <-
              fired([U.TupleSup, U.TupleOwner, U.PermanentTupleOwner], :ets),
            do: mod

      # A restart from a call is unknown: TupleOwner is not shown to come
      # back. The literal :permanent beside it is.
      assert U.TupleOwner in found
      refute U.PermanentTupleOwner in found
    end
  end

  describe "a DynamicSupervisor's max_children" do
    test "no cap in options read whole, :infinity, or a helper's options is uncapped; a merge is unknown" do
      sups =
        for [sup | _] <-
              rows(
                [
                  U.CapsLive,
                  U.TupleOwner,
                  U.Caps.NoCap,
                  U.Caps.InfinityCap,
                  U.Caps.HelperOpts,
                  U.Caps.Capped,
                  U.Caps.MergedOpts
                ],
                :unsafe_input,
                "unbounded_children_from_request"
              ),
            uniq: true,
            do: short(sup)

      assert Enum.sort(sups) == ["HelperOpts", "InfinityCap", "NoCap"]
    end
  end

  describe "a trap_exit flag the extractor cannot read" do
    test "may trap: no finding that the process never traps; no flag, false or a spawned flag still do" do
      found =
        for {_, "Cleanup in terminate/2 of a process that never traps exits", {mod, _, _}} <-
              fired(
                [U.Traps.NoFlag, U.Traps.FalseFlag, U.Traps.SpawnedFlag, U.Traps.UnreadFlag],
                :shutdown
              ),
            do: mod

      assert Enum.sort(found) == [U.Traps.FalseFlag, U.Traps.NoFlag, U.Traps.SpawnedFlag]
    end
  end

  describe "options the extractor knows in part" do
    @describetag flowlog: false

    setup do
      {:ok, facts} =
        Pipeline.extract(
          [U.PartialStarts, U.PartialTables, U.FlagsMapSup, U.Caps.MergedOpts, U.Caps.HelperOpts],
          extractors: [
            Argus.Extractors.ProcessRegistry,
            Argus.Extractors.ETS,
            Argus.Extractors.Supervision
          ]
        )

      %{facts: facts}
    end

    test "a start's name may be in options known in part; none in options read whole", %{
      facts: facts
    } do
      starts =
        for [_id, func, _api, _scope, source, _key] <- facts[:creating_op], do: {func, source}

      assert {inspect(U.PartialStarts) <> ":start_link/1", "dynamic"} in starts
      refute Enum.any?(starts, fn {func, _} -> func =~ "start_unnamed" end)
    end

    test "a table's options known in part are not known whole", %{facts: facts} do
      known = for [id] <- facts[:ets_options_known], do: id
      assert Enum.any?(known, &(&1 =~ "PartialTables:whole/0"))
      refute Enum.any?(known, &(&1 =~ "PartialTables:partial/1"))
    end

    test "a cap in options merged from the argument is unknown; none in a helper's options", %{
      facts: facts
    } do
      caps = for [sup, limit] <- facts[:supervisor_max_children], do: {short(sup), limit}
      assert caps == [{"MergedOpts", "dynamic"}]
    end

    test "a flags map with no strategy takes OTP's default", %{facts: facts} do
      assert [inspect(U.FlagsMapSup), "one_for_one"] in facts[:supervisor]
    end
  end
end
