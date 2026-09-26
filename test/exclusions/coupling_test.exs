defmodule Argus.Exclusions.CouplingTest do
  @moduledoc """
  Exclusions of the coupling analysis that no evaluation program
  exercises (census 2026-09-26). Each test pins what one negated atom
  keeps quiet, beside a twin the analysis does report, so it cannot pass
  on a fixture the analysis does not read as the test assumes. The
  census is docs/design/exclusions.md; the fixtures are in
  test/fixtures/exclusions/coupling.ex.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows

  @linked_hub [
    Excl.Coupling.LinkedHub.Hub,
    Excl.Coupling.LinkedHub.Subscriber,
    Excl.Coupling.LinkedHub.Sup
  ]
  @unlinked_hub [
    Excl.Coupling.UnlinkedHub.Hub,
    Excl.Coupling.UnlinkedHub.Subscriber,
    Excl.Coupling.UnlinkedHub.Sup
  ]
  @private_conn [
    Excl.Coupling.PrivateConn.Conn,
    Excl.Coupling.PrivateConn.Poller,
    Excl.Coupling.PrivateConn.Tree
  ]
  @shared_conn [
    Excl.Coupling.SharedConn.Conn,
    Excl.Coupling.SharedConn.Poller,
    Excl.Coupling.SharedConn.Tree
  ]
  @reset_helper [
    Excl.Coupling.ResetHelper.Cache,
    Excl.Coupling.ResetHelper.Loader,
    Excl.Coupling.ResetHelper.Sup
  ]
  @untested_reset [
    Excl.Coupling.UntestedReset.Cache,
    Excl.Coupling.UntestedReset.Loader,
    Excl.Coupling.UntestedReset.Sup
  ]
  @tagged_keep [
    Excl.Coupling.TaggedKeep.Cache,
    Excl.Coupling.TaggedKeep.Loader,
    Excl.Coupling.TaggedKeep.Sup
  ]
  @untested_keep [
    Excl.Coupling.UntestedKeep.Cache,
    Excl.Coupling.UntestedKeep.Loader,
    Excl.Coupling.UntestedKeep.Sup
  ]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    @linked_hub,
    @unlinked_hub,
    @private_conn,
    @shared_conn,
    @reset_helper,
    @untested_reset,
    @tagged_keep,
    @untested_keep
  ]

  setup_all do
    %{batch: Batch.solve(:coupling, @batched)}
  end

  # {reason, detail, witness function} of each sibling dependency the
  # set reports.
  defp dependencies(%{batch: batch}, set) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)

    results
    |> Rows.where(:coupling, "sibling_dependency",
      drop: [:sup, :caller, :callee, :sup_site, :site, :basis, :permille]
    )
    |> Enum.map(fn [reason, detail, witness] -> {reason, detail, function(witness)} end)
    |> Enum.sort()
  end

  # A witness's function, without its module or instruction.
  defp function(id), do: id |> String.split(":") |> List.last() |> String.split("#") |> hd()

  describe "restart isolation" do
    # coupling.dl, coupling: !derived_process_link(callee_mod, caller_mod).
    test "a hub that links each subscriber it keeps restarts together with them", ctx do
      assert dependencies(ctx, @linked_hub) == []
      assert {"restart_isolation", "state", "handle_call/3"} in dependencies(ctx, @unlinked_hub)
    end

    # restart_state.dl, kept: !initial_field(b, k, v), in the rule for a
    # helper a tagged clause returns through.
    test "a clause returning through a helper that resets a field to its initial value loses nothing",
         ctx do
      witnesses = for {_, _, witness} <- dependencies(ctx, @reset_helper), do: witness
      refute "invalidate_state/1" in witnesses

      assert {"restart_isolation", "state", "keep/2"} in dependencies(ctx, @tagged_keep)
    end

    # restart_state.dl, kept: !initial_field(b, k, v), in the rule for a
    # helper an untested clause returns through.
    test "an untested clause that resets a field to its initial value loses nothing", ctx do
      assert dependencies(ctx, @untested_reset) == []
      assert {"restart_isolation", "state", "keep/2"} in dependencies(ctx, @untested_keep)
    end
  end

  describe "restart policy" do
    # coupling.dl, sibling_dependency: !private_module_dep(perm, sibling).
    test "a permanent child querying only its own instance of a temporary sibling's module",
         ctx do
      assert dependencies(ctx, @private_conn) == []

      assert {"restart_policy", "temporary", "handle_info/2"} in dependencies(ctx, @shared_conn)
    end
  end
end
