defmodule Argus.Extractors.ETSTest do
  use ExUnit.Case, async: true

  alias Argus.Extractors.ETS

  defp disassemble(mod) do
    {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(mod)))
    data
  end

  describe "extract/1" do
    test "detects ets_new for named table" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsOwner))

      assert Map.has_key?(facts, :ets_new)
      rows = facts[:ets_new]
      assert rows != []

      names = Enum.map(rows, fn [_id, _func, name] -> name end)
      assert ":my_cache" in names
    end

    test "extracts ets options" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsOwner))

      assert Map.has_key?(facts, :ets_option)
      options = facts[:ets_option]

      keys = Enum.map(options, fn [_id, key, _val] -> key end)
      assert "type" in keys
      assert "access" in keys
      assert "named_table" in keys

      # Verify specific values.
      assert Enum.any?(options, fn [_, k, v] -> k == "type" and v == "set" end)
      assert Enum.any?(options, fn [_, k, v] -> k == "access" and v == "public" end)
      assert Enum.any?(options, fn [_, k, v] -> k == "named_table" and v == "true" end)
    end

    test "extracts concurrency and heir options from well-configured table" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsWellConfigured))

      assert Map.has_key?(facts, :ets_option)
      options = facts[:ets_option]

      assert Enum.any?(options, fn [_, k, v] -> k == "read_concurrency" and v == "true" end)
      assert Enum.any?(options, fn [_, k, v] -> k == "write_concurrency" and v == "true" end)
      assert Enum.any?(options, fn [_, k, v] -> k == "heir" and v == "true" end)
    end

    test "detects ets read operations" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsReader))

      assert Map.has_key?(facts, :ets_op)
      ops = facts[:ets_op]
      assert ops != []

      assert Enum.any?(ops, fn [_, _, _, op, kind] -> op == "lookup" and kind == "read" end)
    end

    test "detects ets write operations" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsWriter))

      assert Map.has_key?(facts, :ets_op)
      ops = facts[:ets_op]
      assert ops != []

      assert Enum.any?(ops, fn [_, _, _, op, kind] -> op == "insert" and kind == "write" end)
    end

    test "extracts table reference from read operations" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsReader))

      ops = facts[:ets_op]
      refs = Enum.map(ops, fn [_, _, ref, _, _] -> ref end)
      assert ":my_cache" in refs
    end

    test "maps ops on a table ref back to the same-function :ets.new name" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsRefOps))

      ops = facts[:ets_op]

      # `table = :ets.new(:ref_table, ...)` then insert/lookup via the
      # ref: both ops inherit the creation site's table name.
      build_refs =
        for [_, func, ref, op, _] <- ops, func =~ ":build/0", do: {op, ref}

      assert {"insert", ":ref_table"} in build_refs
      assert {"lookup", ":ref_table"} in build_refs

      # The ref survives an intervening call in a y register; the walk
      # follows the move chain across it.
      across_refs =
        for [_, func, ref, op, _] <- ops, func =~ "build_across_call", do: {op, ref}

      assert {"insert", ":ref_table_two"} in across_refs
    end

    test "resolves parameter table references as dynamic, not stale atoms" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsParamTable))

      assert Map.has_key?(facts, :ets_op)
      ops = facts[:ets_op]

      # All table references should be "dynamic" — not ":ok" or other
      # stale values leaked from the preceding clause's return path.
      refs = Enum.map(ops, fn [_, _, ref, _, _] -> ref end)

      assert Enum.all?(refs, &(&1 == "dynamic")),
             "expected all refs to be dynamic, got: #{inspect(refs)}"

      refute ":ok" in refs
    end

    test "classifies delete_all_objects as write" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsAdminOps))

      assert Map.has_key?(facts, :ets_op)
      ops = facts[:ets_op]

      assert Enum.any?(ops, fn [_, _, _, op, kind] ->
               op == "delete_all_objects" and kind == "write"
             end)
    end

    test "classifies give_away, rename, setopts as write" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsAdminOps))

      ops = facts[:ets_op]

      for op_name <- ~w(give_away rename setopts) do
        assert Enum.any?(ops, fn [_, _, _, op, kind] -> op == op_name and kind == "write" end),
               "expected #{op_name} to be classified as write"
      end
    end

    test "classifies safe_fixtable as read" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsAdminOps))

      ops = facts[:ets_op]

      assert Enum.any?(ops, fn [_, _, _, op, kind] ->
               op == "safe_fixtable" and kind == "read"
             end)
    end

    test "returns empty for non-ets module" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.PlainModule))
      assert facts == %{}
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

  describe "integration with extract pipeline" do
    test "extractor is usable via Pipeline.extract/2" do
      assert {:ok, facts} =
               Argus.Pipeline.extract(
                 [Argus.Test.Fixtures.EtsOwner],
                 extractors: [ETS]
               )

      assert Map.has_key?(facts, :ets_new)
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
