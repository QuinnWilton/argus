defmodule Argus.Analyses.EtsPublishOrderTest do
  use ExUnit.Case, async: true

  alias Argus.Analyses.Races
  alias Argus.Souffle
  alias Argus.Test.Fixtures.PublishOrder, as: P

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  defp published(modules) do
    {:ok, results} = Argus.analyze(modules, :races)

    for [_mod, func, _ak, a, _bk, b, publish, complete, reader] <-
          results["ets_publish_order"],
        uniq: true,
        do: {short(func), a, b, short(publish), short(complete), short(reader)}
  end

  describe "ets_publish_order" do
    test "two unnamed tables told apart by the map field they are kept under" do
      skip_without_souffle()

      assert [{"intern/2", ":forward", ":reverse", "intern/2", "intern/2", "resolve/2"}] =
               published([P.MapFields])
    end

    test "the same tables written row first, value second, stay quiet" do
      skip_without_souffle()
      assert published([P.ReverseFirst]) == []
    end

    test "two named tables, the id handed out by a lookup of the first" do
      skip_without_souffle()

      assert [{"register/2", ":users_by_name", ":users_by_id", _, _, "name_of/1"}] =
               published([P.NamedTables])
    end

    test "update_counter/3 on the missing row raises as lookup_element/3 does" do
      skip_without_souffle()

      assert [{"open/2", ":sessions", ":session_hits", _, _, "hit/1"}] =
               published([P.CountedById])
    end

    test "a reader with a default, or one that rescues the miss, stays quiet" do
      skip_without_souffle()
      assert published([P.DefaultedReader, P.RescuedReader]) == []
    end

    test "private tables, and protected ones only their owner touches, stay quiet" do
      skip_without_souffle()
      assert published([P.PrivateTables, P.OwnerOnly]) == []
    end

    test "two tables keyed by the same thing are not a publication" do
      skip_without_souffle()
      assert published([P.SameKey]) == []
    end
  end

  describe "facts" do
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

    test "ets_value and ets_write_order join the id written into one table to the other's key" do
      {:ok, facts} = Argus.Pipeline.extract([P.MapFields], extractors: [Argus.Extractors.ETS])

      [insert_new] = for [id, _, _, "insert_new", _] <- facts.ets_op, do: id
      [insert] = for [id, _, _, "insert", _] <- facts.ets_op, do: id

      assert [[^insert_new, "1", "local", made]] =
               Enum.filter(facts.ets_value, &(hd(&1) == insert_new))

      assert [^insert, "local", ^made] = Enum.find(facts.ets_key, &(hd(&1) == insert))

      assert [_func, ^insert_new, ^insert] =
               Enum.find(facts.ets_write_order, &(Enum.at(&1, 1) == insert_new))

      refute Enum.any?(
               facts.ets_write_order,
               &(Enum.at(&1, 1) == insert and Enum.at(&1, 2) == insert_new)
             )
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

      assert [%{label: "the row it points to is written here"}, %{label: label}] = f.related
      assert label =~ "raises"
      assert Enum.any?(f.help, &(&1 =~ "first"))
    end
  end

  defp short(id), do: id |> String.split("#") |> hd() |> String.split(":") |> List.last()
end
