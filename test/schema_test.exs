defmodule Argus.SchemaTest do
  use ExUnit.Case, async: true

  alias Argus.Schema

  describe "all/0" do
    test "returns a non-empty list of relations" do
      assert Schema.all() != []
    end

    test "every relation has required keys" do
      for rel <- Schema.all() do
        assert is_atom(rel.name), "relation name must be an atom: #{inspect(rel)}"
        assert rel.layer in [1, 2], "layer must be 1 or 2: #{inspect(rel.name)}"
        assert is_list(rel.fields), "fields must be a list: #{inspect(rel.name)}"
        assert rel.fields != [], "fields must be non-empty: #{inspect(rel.name)}"
        assert is_binary(rel.doc), "doc must be a string: #{inspect(rel.name)}"
      end
    end

    test "every field has valid structure" do
      for rel <- Schema.all(), {fname, ftype, fdoc} <- rel.fields do
        assert is_atom(fname),
               "field name must be an atom: #{inspect(rel.name)}.#{inspect(fname)}"

        assert ftype in [:symbol, :number, :instr_id, :func_id, :label],
               "unknown field type #{inspect(ftype)}: #{inspect(rel.name)}.#{inspect(fname)}"

        assert is_binary(fdoc),
               "field doc must be a string: #{inspect(rel.name)}.#{inspect(fname)}"
      end
    end

    test "relation names are unique" do
      names = Enum.map(Schema.all(), & &1.name)
      assert names == Enum.uniq(names)
    end
  end

  describe "layer_1/0" do
    test "all relations have layer 1" do
      for rel <- Schema.layer_1() do
        assert rel.layer == 1
      end
    end
  end

  describe "layer_2/0" do
    test "all relations have layer 2" do
      for rel <- Schema.layer_2() do
        assert rel.layer == 2
      end
    end
  end

  describe "fetch/1" do
    test "returns {:ok, relation} for known names" do
      assert {:ok, %{name: :instruction}} = Schema.fetch(:instruction)
      assert {:ok, %{name: :function_def}} = Schema.fetch(:function_def)
    end

    test "returns :error for unknown names" do
      assert :error = Schema.fetch(:nonexistent)
    end
  end

  describe "names/0" do
    test "returns all relation names" do
      names = Schema.names()
      assert :instruction in names
      assert :function_def in names
      assert :supervisor in names
      assert :implements_behaviour in names
    end
  end
end
