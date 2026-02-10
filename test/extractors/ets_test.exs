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
      assert length(rows) >= 1

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
      assert length(ops) >= 1

      assert Enum.any?(ops, fn [_, _, _, op, kind] -> op == "lookup" and kind == "read" end)
    end

    test "detects ets write operations" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsWriter))

      assert Map.has_key?(facts, :ets_op)
      ops = facts[:ets_op]
      assert length(ops) >= 1

      assert Enum.any?(ops, fn [_, _, _, op, kind] -> op == "insert" and kind == "write" end)
    end

    test "extracts table reference from read operations" do
      facts = ETS.extract(disassemble(Argus.Test.Fixtures.EtsReader))

      ops = facts[:ets_op]
      refs = Enum.map(ops, fn [_, _, ref, _, _] -> ref end)
      assert ":my_cache" in refs
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

  describe "integration with extract pipeline" do
    test "extractor is usable via Extract.extract/2" do
      assert {:ok, facts} =
               Argus.Extract.extract(
                 [Argus.Test.Fixtures.EtsOwner],
                 extractors: [ETS]
               )

      assert Map.has_key?(facts, :ets_new)
    end
  end
end
