defmodule Argus.Analyses.EtsBroadDeleteTest do
  use ExUnit.Case, async: true
  @moduletag :flowlog

  alias Argus.Analyses.Races
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.EtsBroadDelete, as: B

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    B.ReleaseWaiters,
    B.ReleaseReadWaiters,
    B.CancelClaim,
    B.CancelOwnRow,
    B.ReleaseOwnClaim,
    B.OwnerCancels,
    B.TaskTables
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  # {function, table, kind} of each broad delete.
  defp deletes(%{batch: batch}, module) do
    {:ok, results} = Batch.analyze(batch, [module])

    for [_mod, func, name, _key, _before, _delete, kind] <- results["ets_broad_delete"],
        do: {short(func), name, kind}
  end

  defp frames(%{batch: batch}, module, role) do
    {:ok, results} = Batch.analyze(batch, [module])

    for [_delete, ^role, site, _func] <- results["ets_broad_delete_frame"], do: short(site)
  end

  describe "a delete by key after a read of the key's rows" do
    test "takes a waiter's row made after the read: roux 0.3.4's release_dedup/2", ctx do
      assert deletes(ctx, B.ReleaseWaiters) == [{"release/1", ":release_waiters", "after_read"}]
      assert frames(ctx, B.ReleaseWaiters, "rival") == ["wait/1"]
    end

    test "is quiet when the release deletes exactly the rows it read: roux's fix", ctx do
      assert deletes(ctx, B.ReleaseReadWaiters) == []
    end
  end

  describe "a delete by key after a kill" do
    test "takes a claim made after the kill: roux 0.3.4's kill_task/4", ctx do
      assert deletes(ctx, B.CancelClaim) == [{"cancel/2", ":cancel_claims", "after_kill"}]
      assert frames(ctx, B.CancelClaim, "rival") == ["claim/1"]
    end

    test "is quiet when it deletes the killed process's own row: roux's fix", ctx do
      assert deletes(ctx, B.CancelOwnRow) == []
    end

    test "is quiet on a table only its owner writes, which nobody else can claim in", ctx do
      assert deletes(ctx, B.OwnerCancels) == []
    end

    test "on tables one closure makes, kept under fields, names the field", ctx do
      assert deletes(ctx, B.TaskTables) == [{"cancel/3", "field :claims", "after_kill"}]
      # The waiters' delete after the same kill is the same finding.
      assert frames(ctx, B.TaskTables, "also_deletes") == ["cancel/3"]
    end
  end

  test "a claimant's release of its own claim, after neither, is not a broad delete", ctx do
    assert deletes(ctx, B.ReleaseOwnClaim) == []
  end

  describe "finding" do
    @describetag flowlog: false

    test "after a read anchors the delete and relates the read" do
      row = ["M", "M:release/1", ":waiters", "0", "M:release/1#4", "M:release/1#9", "after_read"]
      f = Races.finding(:ets_broad_delete, row)

      assert f.severity == :warning
      assert f.title =~ "never read"
      assert f.detail =~ "reads the rows of a key of :waiters"
      assert [%{label: "the read of the key's rows"}] = f.related
      assert Enum.any?(f.help, &(&1 =~ "delete_object"))
    end

    test "after a kill relates the kill and names the field a site's table is kept under" do
      row = [
        "M",
        "M:cancel/3",
        "field :claims",
        "1",
        "M:cancel/3#4",
        "M:cancel/3#9",
        "after_kill"
      ]

      f = Races.finding(:ets_broad_delete, row)

      assert f.title =~ "after a kill"
      assert f.detail =~ "deletes a key of the table kept under :claims"
      assert [%{label: "the kill"}] = f.related
    end

    test "a rival frame names where another process makes its own row" do
      e =
        Races.evidence(:ets_broad_delete_frame, [
          "M:cancel/3#9",
          "rival",
          "M:claim/1#3",
          "M:claim/1"
        ])

      assert e.label =~ "makes its own row under the key"
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
