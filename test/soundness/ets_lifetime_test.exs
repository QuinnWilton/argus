defmodule Argus.Soundness.EtsLifetimeTest do
  @moduledoc """
  "ETS table read while its owner may be restarting" is reported where a reader outlives
  the table's owner (ets.dl's reader_outlives,
  docs/analyses/ets.md#reads-during-an-owners-restart) and the read can meet the table
  gone.

  The restatement narrows the class in two ways. Each narrowing has
  adversarial shapes of the nearest real bug that must still fire:

  - **A reader that ends with the owner is none.** A child of the owner
    supervisor (`SupChild`), a one_for_all sibling (`AllReader`), a later
    rest_for_one sibling (`RestLater`) and a loader the owner spawns
    linked (`LinkOwner.load/0`) end with it. Still reported: an earlier
    rest_for_one sibling (`RestEarlier`), a one_for_one sibling
    (`OneReader`), a one_for_all sibling of a branch whose own supervisor
    restarts the owner alone (`DeepReader`), and an unlinked loader
    (`UnlinkOwner.load/0`).
  - **A read made where the reader made the table is safe.** An ensure
    helper before the read (`EnsureReader.get/1`) and a whereis-or-make
    inline (`get_inline/1`) are safe. Still reported: an ensure on one
    branch only, an ensure after the read, an ensure of another table,
    and an ensure that makes an unnamed table of the atom.

  It also widens the class. A read the owner's own process runs, which a
  sibling runs too (`SharedOwner.lookup/1` from `SharedClient`), was
  taken as the owner's own and missed.
  """
  use ExUnit.Case, async: true
  @moduletag :souffle

  import Argus.Test.Soundness, only: [fired: 2]

  @title "ETS table read while its owner may be restarting"

  @modules [
    Lifetime.OwnerSup,
    Lifetime.SupChild,
    Lifetime.AllSup,
    Lifetime.AllOwner,
    Lifetime.AllReader,
    Lifetime.RestSup,
    Lifetime.RestOwner,
    Lifetime.RestEarlier,
    Lifetime.RestLater,
    Lifetime.OneSup,
    Lifetime.OneOwner,
    Lifetime.OneReader,
    Lifetime.DeepAllSup,
    Lifetime.DeepBranch,
    Lifetime.DeepOwner,
    Lifetime.DeepReader,
    Lifetime.LinkOwner,
    Lifetime.UnlinkOwner,
    Lifetime.SharedSup,
    Lifetime.SharedOwner,
    Lifetime.SharedClient,
    Lifetime.EnsureOwner,
    Lifetime.EnsureReader
  ]

  setup_all do
    reads = for {sev, @title, mfa} <- fired(@modules, :ets), uniq: true, do: {mfa, sev}
    %{reads: Map.new(reads)}
  end

  @fires [
    {Lifetime.RestEarlier, :handle_call, 3},
    {Lifetime.OneReader, :handle_call, 3},
    {Lifetime.DeepReader, :handle_call, 3},
    {Lifetime.UnlinkOwner, :load, 0},
    {Lifetime.SharedOwner, :lookup, 1},
    {Lifetime.EnsureReader, :get_branch, 2},
    {Lifetime.EnsureReader, :get_after, 1},
    {Lifetime.EnsureReader, :get_other, 1},
    {Lifetime.EnsureReader, :get_unnamed, 1}
  ]

  @quiet [
    {Lifetime.SupChild, :handle_call, 3},
    {Lifetime.AllReader, :handle_call, 3},
    {Lifetime.RestLater, :handle_call, 3},
    {Lifetime.LinkOwner, :load, 0},
    {Lifetime.EnsureReader, :get, 1},
    {Lifetime.EnsureReader, :get_inline, 1}
  ]

  for mfa <- @fires do
    test "#{inspect(mfa)}: a reader that outlives the owner, unprotected, is reported", %{
      reads: reads
    } do
      assert Map.get(reads, unquote(Macro.escape(mfa))) == :info
    end
  end

  for mfa <- @quiet do
    test "#{inspect(mfa)}: no reader outlives the table, or the read makes it", %{reads: reads} do
      refute Map.has_key?(reads, unquote(Macro.escape(mfa)))
    end
  end
end
