defmodule Argus.Extractors.ETSTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ETS

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "match patterns" do
    test "a pattern's key is its first element, unless that is a wildcard" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.CheckThenAct.MatchThenWrite))
      ops = Map.new(facts[:ets_op], fn [id, func, _t, op, _k] -> {id, {func, op}} end)

      keyed =
        for [id, source, key] <- facts[:ets_key],
            {func, "match_object"} <- [ops[id]],
            do: {func |> String.split(":") |> List.last(), source, key}

      assert keyed == [{"bump/1", "param", "0"}]
    end
  end

  describe "a literal named only while an answer is unset" do
    defp defaults(mod) do
      facts = ETS.extract(disassemble(mod))
      ops = Map.new(facts[:ets_op], fn [id, func, _t, op, _k] -> {id, {short(func), op}} end)
      for [id, name, site] <- facts[:ets_table_default], do: {ops[id], name, short(site)}
    end

    test "the unset arm of a case on a call's answer" do
      defaults = defaults(Argus.Test.Fixtures.Dictionary.TmpOptions)

      assert {{"set_option/2", "insert"}, ":dict_options", site} =
               List.keyfind(defaults, {"set_option/2", "insert"}, 0)

      assert site =~ ~r"^set_option/2#\d+$"
      assert List.keyfind(defaults, {"get_option/1", "lookup"}, 0)
    end

    test "the `||` of a read in place, and not of a parameter" do
      assert [{{"put/2", "insert"}, ":or_default", _site}] =
               defaults(Argus.Test.Fixtures.Dictionary.OrDefault)
    end
  end

  describe "keys a value's maker names" do
    defp keys(mod) do
      facts = ETS.extract(disassemble(mod))
      ops = Map.new(facts[:ets_op], fn [id, func, _t, op, _k] -> {id, {short(func), op}} end)
      for [id, source, key] <- facts[:ets_key], do: {ops[id], {source, key}}
    end

    defp short(func), do: func |> String.split(":") |> List.last()

    test "self() is the calling process, however many calls of it" do
      keys = keys(Argus.Test.Fixtures.MissingRow.OwnRow)

      assert {{"hit/0", "lookup"}, {"self", ""}} in keys
      assert {{"hit/0", "update_counter"}, {"self", ""}} in keys
      assert {{"done/0", "delete"}, {"self", ""}} in keys
    end

    test "the key matched out of a row a lookup found is the key it asked for" do
      # The compiler hands the delete the row's element the pinned match
      # compared with the parameter, not the parameter.
      keys = keys(:races_pinned_delete)

      assert {{"delete_node/1", "lookup"}, {"param", "0"}} in keys
      assert {{"delete_node/1", "delete"}, {"param", "0"}} in keys
    end

    test "the key of a row another lookup found is that lookup's" do
      keys = keys(:races_pinned_other)

      assert {{"move/2", "lookup"}, {"param", "0"}} in keys
      assert {{"move/2", "lookup"}, {"param", "1"}} in keys
      assert {{"move/2", "delete"}, {"param", "1"}} in keys
    end

    test "a tuple spelled out at each site is named by its elements" do
      keys = keys(Argus.Test.Fixtures.MissingRow.InlineTupleKey)
      key = {"tuple", "{param 0, param 1}"}

      assert {{"log/2", "lookup"}, key} in keys
      assert {{"log/2", "update_counter"}, key} in keys
      assert {{"log/2", "insert"}, key} in keys
    end
  end

  describe "reads made where the table is there" do
    # The functions of Lifetime.EnsureReader with a read every path to
    # which passes a whereis that found the table or a make of it.
    defp present_readers do
      facts = ETS.extract(disassemble(Lifetime.EnsureReader))
      ops = Map.new(Map.get(facts, :ets_op, []), fn [id, func | _] -> {id, func} end)

      for [read, _witness] <- Map.get(facts, :ets_read_when_present, []), uniq: true do
        ops |> Map.fetch!(read) |> String.split(":") |> List.last()
      end
      |> Enum.sort()
    end

    test "a make before the read, through an ensure helper or inline, and nothing else" do
      assert present_readers() == ["get/1", "get_inline/1"]
    end
  end

  describe "extract/1" do
    alias Argus.Test.Fixtures, as: F

    # A module's ets_new rows, by function, each with the ets_option rows
    # its id carries: [func, name, [[key, value], ...]].
    defp tables(mod) do
      facts = ETS.extract(disassemble(mod))
      news = Map.get(facts, :ets_new, [])
      options = Map.get(facts, :ets_option, [])
      ids = for [id, _func, _name] <- news, do: id

      # An option belongs to a creation site.
      assert Enum.reject(options, fn [id | _] -> id in ids end) == []

      news
      |> Enum.map(fn [id, func, name] ->
        assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
        [short(func), name, Enum.sort(for [^id, key, value] <- options, do: [key, value])]
      end)
      |> Enum.sort()
    end

    # A module's ets_op rows, by function: [func, table, op, kind].
    defp ops(mod) do
      ETS.extract(disassemble(mod))
      |> Map.get(:ets_op, [])
      |> Enum.map(fn [id, func | rest] ->
        assert id =~ ~r/^#{Regex.escape(func)}#\d+$/
        [short(func) | rest]
      end)
      |> Enum.sort()
    end

    test "each table made, with the options its list spells" do
      assert tables(F.EtsOwner) == [
               [
                 "init/1",
                 ":my_cache",
                 [["access", "public"], ["named_table", "true"], ["type", "set"]]
               ]
             ]

      assert tables(F.EtsWellConfigured) == [
               [
                 "init/1",
                 ":safe",
                 [
                   ["access", "public"],
                   ["heir", "true"],
                   ["named_table", "true"],
                   ["read_concurrency", "true"],
                   ["type", "set"],
                   ["write_concurrency", "true"]
                 ]
               ]
             ]

      # A table keyed past the first element says which; one that names
      # no type has no type row.
      assert tables(F.CheckThenAct.RecordTable) == [
               [
                 "start/0",
                 ":accts",
                 [["access", "public"], ["keypos", "2"], ["named_table", "true"]]
               ]
             ]
    end

    test "each op with its table and kind" do
      for {mod, rows} <- [
            {F.EtsReader, [["lookup/1", ":my_cache", "lookup", "read"]]},
            {F.EtsWriter, [["put/2", ":my_cache", "insert", "write"]]},
            # An op on a table reference names the table the same
            # function's :ets.new made, across a call that parks the
            # reference in a y register too.
            {F.EtsRefOps,
             [
               ["build/0", ":ref_table", "insert", "write"],
               ["build/0", ":ref_table", "lookup", "read"],
               ["build_across_call/0", ":ref_table_two", "insert", "write"]
             ]},
            # A parameter is dynamic, not the :ok the clause before it
            # leaves in x0.
            {F.EtsParamTable,
             [
               ["insert/2", "dynamic", "insert", "write"],
               ["lookup/1", "dynamic", "lookup", "read"]
             ]},
            # Each admin op changes the table but safe_fixtable, which
            # only pins a traversal.
            {F.EtsAdminOps,
             [
               ["delete_all/1", "dynamic", "delete_all_objects", "write"],
               ["delete_matching/1", "dynamic", "match_delete", "write"],
               ["fix_table/1", "dynamic", "safe_fixtable", "read"],
               ["give_away/2", "dynamic", "give_away", "write"],
               ["rename_table/2", "dynamic", "rename", "write"],
               ["set_opts/1", "dynamic", "setopts", "write"]
             ]}
          ] do
        assert {mod, ops(mod)} == {mod, rows}
      end
    end
  end

  describe "extract/1 — tables handed on" do
    test "a table reference passed to a helper names the table" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.CheckThenAct.UnnamedTable))

      assert [[caller, callee, "0", ":unnamed_counts"]] = facts[:ets_tid_arg]
      assert caller =~ "start/1"
      assert callee =~ "count/2"
    end

    test "a table reference a closure captures names the table at its environment parameter" do
      facts = ETS.extract(disassemble(:padl2010_ets_inc))

      # The compiler orders the environment; the closure forwards whichever
      # slot holds the table as ets_inc/2's first argument.
      assert [[":padl2010_ets_inc:run/0", closure, pos, ":some_tab_name"]] = facts[:ets_tid_arg]
      assert closure =~ "-run/0-fun-0-"
      assert pos in ["0", "1"]
    end
  end

  describe "a table held in the server's state" do
    test "an op on state.table names the table init/1 stored there" do
      [{_mod, bin}] =
        Code.compile_string("""
        defmodule Argus.ETSTest.StateTable do
          use GenServer
          def init(_), do: {:ok, %{table: :ets.new(:sessions, [:set]), other: :ets.new(:a, [])}}
          def handle_call({:get, k}, _from, state), do: {:reply, :ets.lookup(state.table, k), state}

          def handle_cast({:put, k, v}, %{table: t} = state) do
            :ets.insert(t, {k, v})
            {:noreply, state}
          end

          def handle_info(:swap, state), do: {:noreply, Map.put(state, :other, :ets.new(:b, []))}
          def handle_info({:scan, k}, state), do: {:noreply, :ets.lookup(state.other, k)}
        end
        """)

      {:ok, data} = Argus.Pipeline.Disassemble.disassemble_path(bin)

      ops =
        for [_id, func, table, op, _kind] <- ETS.extract(data)[:ets_op],
            do: {func |> String.split(":") |> List.last(), op, table}

      assert {"handle_call/3", "lookup", ":sessions"} in ops
      assert {"handle_cast/2", "insert", ":sessions"} in ops
      # :other holds two tables in this module: it names neither.
      assert {"handle_info/2", "lookup", "dynamic"} in ops
    end
  end
end
