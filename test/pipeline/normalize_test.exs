defmodule Argus.Pipeline.NormalizeTest do
  use ExUnit.Case, async: true

  alias Argus.Pipeline.Normalize

  describe "func_id/3" do
    test "formats Elixir module" do
      assert Normalize.func_id(Enum, :map, 2) == "Enum:map/2"
    end

    test "formats Erlang module" do
      assert Normalize.func_id(:lists, :reverse, 1) == ":lists:reverse/1"
    end
  end

  describe "normalize_function/2" do
    test "assigns sequential IDs" do
      func = {:function, :foo, 2, 1, [{:label, 1}, {:move, {:x, 0}, {:x, 1}}, :return]}

      result = Normalize.normalize_function(MyMod, func)

      assert [
               {"MyMod:foo/2#0", {:label, 1}},
               {"MyMod:foo/2#1", {:move, {:x, 0}, {:x, 1}}},
               {"MyMod:foo/2#2", :return}
             ] = result
    end

    test "strips typed registers" do
      func =
        {:function, :bar, 1, 1,
         [
           {:gc_bif, :+, {:f, 0}, 1, [{:tr, {:x, 0}, {:t_integer, :any}}, {:integer, 1}], {:x, 0}}
         ]}

      [{_id, instr}] = Normalize.normalize_function(MyMod, func)

      assert {:gc_bif, :+, {:f, 0}, 1, [{:x, 0}, {:integer, 1}], {:x, 0}} = instr
    end

    test "normalizes alloc hints in allocate_heap" do
      func =
        {:function, :baz, 0, 1,
         [
           {:allocate_heap, 3, {:alloc, [words: 5, floats: 0, funs: 1]}, 2}
         ]}

      [{_id, instr}] = Normalize.normalize_function(MyMod, func)

      # The alloc keyword list is replaced with the word count.
      assert {:allocate_heap, 3, 5, 2} = instr
    end

    test "normalizes alloc hints in test_heap" do
      func =
        {:function, :qux, 0, 1,
         [
           {:test_heap, {:alloc, [words: 3, floats: 0, funs: 2]}, 2}
         ]}

      [{_id, instr}] = Normalize.normalize_function(MyMod, func)

      assert {:test_heap, 3, 2} = instr
    end

    test "preserves simple instructions" do
      func =
        {:function, :id, 1, 1,
         [
           {:label, 1},
           {:line, 42},
           {:func_info, {:atom, MyMod}, {:atom, :id}, 1},
           {:label, 2},
           :return
         ]}

      result = Normalize.normalize_function(MyMod, func)

      assert [
               {_, {:label, 1}},
               {_, {:line, 42}},
               {_, {:func_info, {:atom, MyMod}, {:atom, :id}, 1}},
               {_, {:label, 2}},
               {_, :return}
             ] = result
    end

    test "strips typed registers in nested structures" do
      func =
        {:function, :test, 1, 1,
         [
           {:get_map_elements, {:f, 5}, {:tr, {:x, 0}, {:t_map, :any, :any}},
            {:list, [{:atom, :key}, {:x, 1}]}}
         ]}

      [{_id, instr}] = Normalize.normalize_function(MyMod, func)

      assert {:get_map_elements, {:f, 5}, {:x, 0}, {:list, [{:atom, :key}, {:x, 1}]}} = instr
    end

    test "works with real module" do
      {:ok, data} = BeamSpy.BeamFile.disassemble(to_string(:code.which(:lists)))
      [func | _] = data.functions
      result = Normalize.normalize_function(data.module, func)

      assert is_list(result)
      assert length(result) > 0

      for {id, _instr} <- result do
        assert is_binary(id)
        assert String.starts_with?(id, ":lists:")
      end
    end
  end
end
