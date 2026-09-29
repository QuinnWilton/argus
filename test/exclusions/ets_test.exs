defmodule Argus.Exclusions.EtsTest do
  @moduledoc """
  Regression cases for ETS exclusions. Suppressed cases have a reported
  twin or supporting row so missing extraction cannot make the check pass.
  Fixtures: test/fixtures/exclusions/ets.ex and test/fixtures/erl/excl_ets_*.erl.
  """
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Rows

  @heir_keeper [Excl.Ets.HeirKeeper]
  @heirless_keeper [Excl.Ets.HeirlessKeeper]
  @auto_counters [Excl.Ets.AutoCounters, Excl.Ets.AutoCounters.Reset]
  @locked_counters [Excl.Ets.LockedCounters, Excl.Ets.LockedCounters.Reset]
  @scratch [Excl.Ets.ScratchUnderModuleName]
  @dynamic_heir [Excl.Ets.DynamicHeir]
  @dynamic_no_heir [Excl.Ets.DynamicNoHeir]
  @helper_asks [Excl.Ets.HelperAsks]
  @start_asks [Excl.Ets.StartAsks]
  @helper_gives [Excl.Ets.HelperGives]
  @start_gives [Excl.Ets.StartGives]
  @helper_creates [Excl.Ets.HelperCreates]
  @tenant_table [
    Excl.Ets.TenantTable.App,
    Excl.Ets.TenantTable.Sup,
    Excl.Ets.TenantTable.Worker,
    Excl.Ets.TenantTable.Tenants
  ]
  @embedded_sup [
    :excl_ets_embed_app,
    :excl_ets_embed_sup,
    :excl_ets_embed_worker,
    :excl_ets_embed_host
  ]

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against a
  # solve of its own).
  @batched [
    @heir_keeper,
    @heirless_keeper,
    @auto_counters,
    @locked_counters,
    @scratch,
    @dynamic_heir,
    @dynamic_no_heir,
    @helper_asks,
    @start_asks,
    @helper_gives,
    @start_gives,
    @helper_creates,
    @tenant_table,
    @embedded_sup
  ]

  setup_all do
    %{batch: Batch.solve(:ets, @batched)}
  end

  # The set's rows of `relation`, with the `drop` columns removed.
  defp rows(%{batch: batch}, set, relation, drop) do
    unless Souffle.available?(), do: flunk("souffle not installed")
    {:ok, results} = Batch.analyze(batch, set)
    Rows.where(results, :ets, relation, drop: drop)
  end

  # {table, reader function} of each read outside the owner.
  defp outside_reads(ctx, set) do
    for [name, reader] <- rows(ctx, set, "ets_read_outside_owner", [:owner, :site, :created]),
        do: {name, reader |> String.split(":") |> List.last()}
  end

  defp unprotected(ctx, set), do: rows(ctx, set, "ets_unprotected_owner", [:mod, :site])

  defp created_in_start(ctx, set),
    do: rows(ctx, set, "ets_created_in_start", [:mod, :site, :start])

  describe "a table that outlives its owner" do
    # ets.dl, ets_unprotected_owner: !ets_option(id, "heir", "true").
    test "a keeper process's table whose heir is the server that spawned it", ctx do
      assert unprotected(ctx, @heir_keeper) == []
      assert unprotected(ctx, @heirless_keeper) == [[":excl_heirless_keeper_cache"]]
    end

    # ets.dl, ets_read_outside_owner: !ets_option(id, "heir", "true").
    test "a table named from the options, made with a heir, read from callers", ctx do
      assert outside_reads(ctx, @dynamic_heir) == []
      assert outside_reads(ctx, @dynamic_no_heir) == [{"dynamic", "lookup/2"}]
    end

    # ets.dl, read_can_be: !unnamed_site(n).
    test "a scratch table made unnamed under the module's own atom is the caller's", ctx do
      reads = outside_reads(ctx, @scratch)
      refute Enum.any?(reads, fn {_, reader} -> reader == "top/2" end)
      assert {"Excl.Ets.ScratchUnderModuleName", "get/1"} in reads
    end
  end

  describe "a table's write concurrency" do
    # ets.dl, ets_missing_write_concurrency:
    # !ets_option(id, "write_concurrency", "auto").
    test "write_concurrency: :auto is write concurrency", ctx do
      assert rows(ctx, @auto_counters, "ets_missing_write_concurrency", [:mod, :site]) == []

      assert rows(ctx, @locked_counters, "ets_missing_write_concurrency", [:mod, :site]) ==
               [[":excl_locked_counters"]]
    end
  end

  describe "a named table a server's start_link makes, through a helper" do
    # ets.dl, ets_created_in_start: !asks_first(f).
    test "the helper that makes it asks :ets.whereis/1 first", ctx do
      assert created_in_start(ctx, @helper_asks) == []
      assert created_in_start(ctx, @helper_creates) == [[":excl_helper_creates"]]
    end

    # ets.dl, ets_created_in_start: !asks_first(s).
    test "start_link asks :ets.whereis/1 before it calls the helper", ctx do
      assert created_in_start(ctx, @start_asks) == []
      assert created_in_start(ctx, @helper_creates) == [[":excl_helper_creates"]]
    end

    # ets.dl, ets_created_in_start: !gives_table_away(f).
    test "the helper that makes it gives it to the server start_link started", ctx do
      assert created_in_start(ctx, @helper_gives) == []
      assert created_in_start(ctx, @helper_creates) == [[":excl_helper_creates"]]
    end

    # ets.dl, ets_created_in_start: !gives_table_away(s).
    test "start_link gives the helper's table to the server it started", ctx do
      assert created_in_start(ctx, @start_gives) == []
      assert created_in_start(ctx, @helper_creates) == [[":excl_helper_creates"]]
    end
  end

  describe "kept: a supervisor another supervisor starts is no application root" do
    # supervision.dl, application_root: !dynamic_child(_, sup, _).
    test "a tenant supervisor the application starts and a DynamicSupervisor restarts", ctx do
      assert outside_reads(ctx, @tenant_table) == [{":excl_tenant_routes", "route/1"}]
    end

    # supervision.dl, application_root: !added_child(_, sup, _, _, _).
    test "an application's top supervisor a host adds under its own with start_child", ctx do
      assert outside_reads(ctx, @embedded_sup) == [{":excl_ets_embed_members", "members/0"}]
    end
  end
end
