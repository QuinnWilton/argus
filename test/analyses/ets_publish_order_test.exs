defmodule Argus.Analyses.EtsPublishOrderTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Batch
  alias Argus.Test.Fixtures.PublishOrder, as: P

  # Every test reads its fixtures' rows from one solve of them all
  # (`Argus.Test.Batch`; ARGUS_VERIFY_BATCH=1 checks each slice against
  # a solve of its own).
  @batched [
    P.MapFields,
    P.ReverseFirst,
    P.NamedTables,
    P.CountedById,
    P.LocalPair,
    P.LocalPairSafe,
    P.SameFieldTwoMaps,
    P.HelperCompletes,
    P.HelperFirst,
    P.KeyFromElsewhere,
    P.KeyFromFirst,
    P.DefaultedReader,
    P.RescuedReader,
    P.UnrelatedRescueReader,
    P.WrongRescueReader,
    P.CallerRescuesReader,
    P.PrivateTables,
    P.OwnerOnly,
    P.SameKey
  ]

  setup_all do
    %{batch: Batch.solve(:races, [@batched])}
  end

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp published(%{batch: batch}, modules) do
    {:ok, results} = Batch.analyze(batch, modules)

    for [_mod, func, _ak, a, _bk, b, publish, complete, reader] <-
          results["ets_publish_order"],
        uniq: true,
        do: {short(func), a, b, short(publish), short(complete), short(reader)}
  end

  describe "ets_publish_order" do
    test "two unnamed tables told apart by the map field they are kept under", ctx do
      skip_without_souffle()

      assert [{"intern/2", forward, reverse, "intern/2", "intern/2", "resolve/2"}] =
               published(ctx, [P.MapFields])

      assert String.ends_with?(forward, "MapFields :forward")
      assert String.ends_with?(reverse, "MapFields :reverse")
    end

    test "the same tables written row first, value second, stay quiet", ctx do
      skip_without_souffle()
      assert published(ctx, [P.ReverseFirst]) == []
    end

    test "two named tables, the id handed out by a lookup of the first", ctx do
      skip_without_souffle()

      assert [{"register/2", ":users_by_name", ":users_by_id", _, _, "name_of/1"}] =
               published(ctx, [P.NamedTables])
    end

    test "update_counter/3 on the missing row raises as lookup_element/3 does", ctx do
      skip_without_souffle()

      assert [{"open/2", ":sessions", ":session_hits", _, _, "hit/1"}] =
               published(ctx, [P.CountedById])
    end

    test "unnamed tables in a tuple, known by the :ets.new/2 that made each", ctx do
      skip_without_souffle()

      assert [{"register/2", first, second, "register/2", "register/2", "name_of/2"}] =
               published(ctx, [P.LocalPair])

      assert first =~ "LocalPair:new/0#"
      assert second =~ "LocalPair:new/0#"
      assert first != second
      assert published(ctx, [P.LocalPairSafe]) == []
    end

    test "one field name in two maps is two tables when each was made apart", ctx do
      skip_without_souffle()

      assert [{"register/3", first, second, _, _, "name_of/2"}] =
               published(ctx, [P.SameFieldTwoMaps])

      assert first != second
    end

    test "the row a helper writes after the value is published", ctx do
      skip_without_souffle()

      assert [{"add/1", ":people_by_name", ":people_by_id", "add/1", "index/2", "name_of/1"}] =
               published(ctx, [P.HelperCompletes])

      assert published(ctx, [P.HelperFirst]) == []
    end

    test "a reader that is never handed a value from the first table stays quiet", ctx do
      skip_without_souffle()
      assert published(ctx, [P.KeyFromElsewhere]) == []

      assert [{"add/1", ":boats_by_name", ":boats_by_id", _, _, "name_at/1"}] =
               published(ctx, [P.KeyFromFirst])
    end

    test "a reader with a default, or one that rescues the miss, stays quiet", ctx do
      skip_without_souffle()
      assert published(ctx, [P.DefaultedReader, P.RescuedReader]) == []
    end

    test "a reader that rescues only other code after the read is reported", ctx do
      skip_without_souffle()

      assert [{"register/2", ":peers_by_name", ":peers_by_id", _, _, "name_of/2"}] =
               published(ctx, [P.UnrelatedRescueReader])
    end

    test "a reader that rescues another exception is reported", ctx do
      skip_without_souffle()

      assert [{"register/2", ":nodes_by_name", ":nodes_by_id", _, _, "name_of/1"}] =
               published(ctx, [P.WrongRescueReader])
    end

    test "a private reader whose one caller rescues the miss stays quiet", ctx do
      skip_without_souffle()
      assert published(ctx, [P.CallerRescuesReader]) == []
    end

    test "private tables, and protected ones only their owner touches, stay quiet", ctx do
      skip_without_souffle()
      assert published(ctx, [P.PrivateTables, P.OwnerOnly]) == []
    end

    test "two tables keyed by the same thing are not a publication", ctx do
      skip_without_souffle()
      assert published(ctx, [P.SameKey]) == []
    end
  end

  describe "facts" do
    test "ets_table_path keeps each arm of a join" do
      {:ok, facts} =
        Argus.Pipeline.extract([Argus.Test.Fixtures.MissingRow.Debounce],
          extractors: [Argus.Extractors.ETS]
        )

      [lookup] = for [id, _, _, "lookup", _] <- facts.ets_op, do: id
      paths = for [^lookup, source, root, path] <- facts.ets_table_path, do: {source, root, path}

      assert {"literal", ":debounce_buckets", ""} in paths
      assert {"param", "0", ":table_name"} in paths
    end

    test "take is a read and a write" do
      {:ok, facts} =
        Argus.Pipeline.extract([Argus.Test.Fixtures.MissingRow.Debounce],
          extractors: [Argus.Extractors.ETS]
        )

      kinds = for [_, _, _, "take", kind] <- facts.ets_op, do: kind
      assert Enum.sort(kinds) == ["read", "write"]
    end

    test "ets_table_path names each table by the parameter field it is read from" do
      {:ok, facts} = Argus.Pipeline.extract([P.MapFields], extractors: [Argus.Extractors.ETS])

      paths =
        for [id, source, root, path] <- facts.ets_table_path,
            uniq: true,
            do: {short(id), source, root, path}

      assert {"intern/2", "param", "0", ":forward"} in paths
      assert {"intern/2", "param", "0", ":reverse"} in paths
      assert {"resolve/2", "param", "0", ":reverse"} in paths
    end

    test "ets_value and ets_effect_order join the id written into one table to the other's key" do
      {:ok, facts} = Argus.Pipeline.extract([P.MapFields], extractors: [Argus.Extractors.ETS])

      [insert_new] = for [id, _, _, "insert_new", _] <- facts.ets_op, do: id
      [insert] = for [id, _, _, "insert", _] <- facts.ets_op, do: id

      assert [[^insert_new, "1", "local", made]] =
               Enum.filter(facts.ets_value, &(hd(&1) == insert_new))

      assert [^insert, "local", ^made] = Enum.find(facts.ets_key, &(hd(&1) == insert))

      assert Enum.any?(facts.ets_effect_order, &match?([_, ^insert_new, ^insert], &1))
      refute Enum.any?(facts.ets_effect_order, &match?([_, ^insert, ^insert_new], &1))
    end
  end

  describe "finding" do
    test "anchors the early write and relates the completing write and the reader" do
      row = [
        "M",
        "M:intern/2",
        "field",
        ":forward",
        "field",
        ":reverse",
        "M:intern/2#33",
        "M:intern/2#57",
        "M:resolve/2#8"
      ]

      f = Races.finding(:ets_publish_order, row)
      assert f.severity == :warning
      assert f.title == "ETS row published before the row it points to"
      assert f.mfa == {M, :intern, 2}
      assert f.detail =~ "the table held under :forward"
      assert f.detail =~ "in M.resolve/2"
      assert f.at_label == "this publishes the value before its row in :reverse exists"

      assert [
               %{label: "the row it points to is written here"},
               %{label: "a read that raises if the row is not there yet"}
             ] = f.related

      assert Enum.any?(f.help, &(&1 =~ "first"))
    end

    test "the label names a field table by its path and a named table by its name" do
      label = fn kind, table ->
        row = [
          "M",
          "M:add/1",
          kind,
          ":by_name",
          kind,
          table,
          "M:add/1#3",
          "M:add/1#9",
          "M:get/1#2"
        ]

        Races.finding(:ets_publish_order, row).at_label
      end

      assert label.("field", "M :state.:by_id") ==
               "this publishes the value before its row in :state.:by_id exists"

      assert label.("named", ":by_id") ==
               "this publishes the value before its row in :by_id exists"
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
