defmodule Argus.FactsTest do
  use ExUnit.Case, async: true

  alias Argus.{Facts, InstrId, Pipeline, Schema}

  describe "decode/1" do
    test "decodes every Layer-1 relation of a real module against the schema" do
      {:ok, raw} = Pipeline.extract([:lists])
      decoded = Facts.decode(raw)

      for {relation, rows} <- decoded, rows != [] do
        {:ok, %{fields: fields}} = Schema.fetch(relation)
        names = Enum.map(fields, &elem(&1, 0))

        for row <- rows do
          assert Map.keys(row) |> Enum.sort() == Enum.sort(names),
                 "#{relation} row keys diverge from schema"
        end

        for row <- rows, {name, kind, _doc} <- fields do
          case kind do
            :instr_id -> assert %InstrId{} = row[name]
            :number -> assert is_integer(row[name])
            :label -> assert is_integer(row[name])
            _ -> assert is_binary(row[name])
          end
        end
      end
    end

    test "extract with format: :typed returns decoded rows" do
      {:ok, typed} = Pipeline.extract([:lists], format: :typed)

      assert [%{id: %InstrId{idx: idx}, op: op} | _] = typed[:instruction]
      assert is_integer(idx) and is_binary(op)

      assert Enum.all?(typed[:jump], fn row -> is_integer(row.target) end)
      assert Enum.all?(typed[:branch], fn row -> row.reserved == 0 end)
    end

    test "unknown relations pass through undecoded" do
      raw = %{custom_relation: [["a", "b"]]}
      assert Facts.decode(raw) == %{custom_relation: [["a", "b"]]}
    end

    test "a row that violates its schema raises loudly" do
      assert_raise ArgumentError, ~r/expects 2 fields/, fn ->
        Facts.decode(%{jump: [["only-one-field"]]})
      end

      assert_raise ArgumentError, ~r/expected label/, fn ->
        Facts.decode(%{jump: [["Mod:f/1#0", "not-a-number"]]})
      end

      assert_raise ArgumentError, ~r/malformed instruction ID/, fn ->
        Facts.decode(%{jump: [["not an id", "3"]]})
      end
    end
  end

  describe "instruction-index parity with beam_disasm" do
    test "argus indices are dense and 1:1 with the raw disassembly stream" do
      # Downstream consumers (lowdown) join argus facts onto beam_disasm
      # instruction streams *by index*. That only works because Normalize
      # indexes the same raw stream beam_disasm produces — including label
      # and line pseudo-instructions. This pins the cross-library invariant.
      path = to_string(:code.which(:lists))
      {:ok, typed} = Pipeline.extract([path], format: :typed)

      argus_counts =
        typed[:instruction]
        |> Enum.group_by(&InstrId.fa(&1.id), & &1.id.idx)
        |> Map.new(fn {fa, idxs} -> {fa, Enum.max(idxs) + 1} end)

      {:beam_file, _mod, _exports, _attrs, _info, functions} =
        path |> File.read!() |> :beam_disasm.file()

      disasm_counts =
        Map.new(functions, fn {:function, name, arity, _entry, instructions} ->
          {{to_string(name), arity}, length(instructions)}
        end)

      assert map_size(argus_counts) > 0

      for {fa, count} <- argus_counts do
        assert disasm_counts[fa] == count,
               "index parity broken for #{inspect(fa)}: argus #{count}, disasm #{inspect(disasm_counts[fa])}"
      end
    end
  end

  describe "canonicalize/1" do
    # Extraction fans out over Task.async_stream and merges by concatenation,
    # so before `ordered: true` the same modules produced a different value on
    # every run. These two tests pin the pair of properties that replaced it:
    # a fixed input order is reproducible, and canonicalize/1 is what makes
    # differing input orders comparable.
    @modules [:lists, :maps, :orddict, :sets, :queue, :gb_trees]

    test "extraction is reproducible for a fixed input order" do
      results = for _ <- 1..8, do: elem(Pipeline.extract(@modules), 1)

      assert results |> Enum.uniq() |> length() == 1,
             "extract/2 returned differing values for identical input"
    end

    test "canonicalize/1 makes a shuffled input order compare equal" do
      {:ok, a} = Pipeline.extract(@modules)
      {:ok, b} = Pipeline.extract(Enum.reverse(@modules))

      # The precondition: row order really does follow input order, so this
      # test would pass vacuously if extraction happened to be order-blind.
      refute a == b, "input order no longer affects row order; this test is vacuous"

      assert Facts.canonicalize(a) == Facts.canonicalize(b)
    end

    test "canonicalizing typed rows works too" do
      {:ok, raw} = Pipeline.extract(@modules)
      typed = Facts.decode(raw)

      assert Facts.canonicalize(typed) == Facts.canonicalize(Facts.decode(raw))
      assert Map.keys(Facts.canonicalize(typed)) == Map.keys(typed)
    end

    test "is idempotent and preserves every row" do
      {:ok, raw} = Pipeline.extract(@modules)
      once = Facts.canonicalize(raw)

      assert Facts.canonicalize(once) == once

      for {relation, rows} <- raw do
        assert Enum.sort(rows) == Enum.sort(once[relation]),
               "#{relation} lost or gained rows under canonicalization"
      end
    end
  end
end
