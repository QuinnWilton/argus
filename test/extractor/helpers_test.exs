defmodule Argus.Extractor.HelpersTest do
  use ExUnit.Case, async: true

  alias Argus.Extractor.Helpers

  describe "add_fact/3" do
    test "adds row to empty facts map" do
      assert Helpers.add_fact(%{}, :my_rel, ["a", "b"]) == %{my_rel: [["a", "b"]]}
    end

    test "prepends row to existing relation" do
      facts = %{my_rel: [["x", "y"]]}
      result = Helpers.add_fact(facts, :my_rel, ["a", "b"])
      assert result == %{my_rel: [["a", "b"], ["x", "y"]]}
    end

    test "adds to separate relations independently" do
      facts =
        %{}
        |> Helpers.add_fact(:rel_a, ["1"])
        |> Helpers.add_fact(:rel_b, ["2"])

      assert facts == %{rel_a: [["1"]], rel_b: [["2"]]}
    end
  end

  describe "get_behaviours/1" do
    test "extracts :behaviour attribute" do
      assert Helpers.get_behaviours(behaviour: [GenServer]) == [GenServer]
    end

    test "extracts :behavior attribute" do
      assert Helpers.get_behaviours(behavior: [Supervisor]) == [Supervisor]
    end

    test "merges both spellings" do
      attrs = [behaviour: [GenServer], behavior: [Supervisor]]
      assert Helpers.get_behaviours(attrs) == [GenServer, Supervisor]
    end

    test "returns empty list for no behaviours" do
      assert Helpers.get_behaviours(vsn: [123]) == []
    end
  end

  describe "match_local_call/1" do
    test "matches call with MFA target" do
      instr = {:call, 1, {MyModule, :helper, 1}}
      assert Helpers.match_local_call(instr) == {:ok, MyModule, :helper, 1}
    end

    test "matches call_only with MFA target" do
      instr = {:call_only, 1, {MyModule, :helper, 1}}
      assert Helpers.match_local_call(instr) == {:ok, MyModule, :helper, 1}
    end

    test "matches call_last with MFA target" do
      instr = {:call_last, 1, {MyModule, :helper, 1}, 2}
      assert Helpers.match_local_call(instr) == {:ok, MyModule, :helper, 1}
    end

    test "returns :none for remote call" do
      assert Helpers.match_local_call({:call_ext, 2, {:extfunc, :ets, :new, 2}}) == :none
    end

    test "returns :none for non-call" do
      assert Helpers.match_local_call({:move, {:atom, :foo}, {:x, 0}}) == :none
    end
  end

  describe "find_function/3" do
    test "finds function by name and arity" do
      functions = [
        {:function, :init, 1, 5, [{:label, 5}, {:move, {:atom, :ok}, {:x, 0}}]},
        {:function, :start, 2, 10, [{:label, 10}]}
      ]

      assert Helpers.find_function(functions, :init, 1) ==
               [{:label, 5}, {:move, {:atom, :ok}, {:x, 0}}]
    end

    test "returns nil for missing function" do
      functions = [{:function, :init, 1, 5, []}]
      assert Helpers.find_function(functions, :start, 2) == nil
    end
  end

  describe "match_remote_call/1" do
    test "matches call_ext" do
      instr = {:call_ext, 2, {:extfunc, :ets, :new, 2}}
      assert Helpers.match_remote_call(instr) == {:ok, :ets, :new, 2}
    end

    test "matches call_ext_only" do
      instr = {:call_ext_only, 2, {:extfunc, GenServer, :call, 2}}
      assert Helpers.match_remote_call(instr) == {:ok, GenServer, :call, 2}
    end

    test "matches call_ext_last" do
      instr = {:call_ext_last, 2, {:extfunc, GenServer, :cast, 2}, 3}
      assert Helpers.match_remote_call(instr) == {:ok, GenServer, :cast, 2}
    end

    test "returns :none for non-call instruction" do
      assert Helpers.match_remote_call({:move, {:atom, :foo}, {:x, 0}}) == :none
      assert Helpers.match_remote_call({:label, 5}) == :none
    end
  end

  describe "resolve_register/3" do
    test "resolves atom move" do
      instrs = [
        {:move, {:atom, :foo}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, :foo}
    end

    test "resolves literal move" do
      instrs = [
        {:move, {:literal, [1, 2, 3]}, {:x, 1}},
        {:call_ext, 2, {:extfunc, :ets, :new, 2}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 1}) == {:ok, [1, 2, 3]}
    end

    test "resolves integer move" do
      instrs = [
        {:move, {:integer, 42}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :integer_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, 42}
    end

    test "resolves register-to-register move" do
      instrs = [
        {:move, {:atom, :bar}, {:x, 1}},
        {:move, {:x, 1}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, :bar}
    end

    test "resolves put_list chain building a list" do
      # Builds [:a, :b, :c] via: put_list(:c, [], x0), put_list(:b, x0, x0), put_list(:a, x0, x0)
      # In instruction order (forward): build from the tail.
      instrs = [
        {:put_list, {:atom, :c}, nil, {:x, 0}},
        {:put_list, {:atom, :b}, {:x, 0}, {:x, 0}},
        {:put_list, {:atom, :a}, {:x, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :length, 1}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == {:ok, [:a, :b, :c]}
    end

    test "resolves put_list with literal tail" do
      instrs = [
        {:put_list, {:atom, :first}, {:literal, [:second, :third]}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :length, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, [:first, :second, :third]}
    end

    test "resolves put_tuple2" do
      instrs = [
        {:put_tuple2, {:x, 0}, {:list, [{:atom, :heir}, {:atom, :none}]}},
        {:call_ext, 1, {:extfunc, :erlang, :tuple_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, {:heir, :none}}
    end

    test "resolves nested put_tuple2 in put_list" do
      # Builds [{:heir, :none}] — tuple in x1, then put_list(x1, [], x0).
      instrs = [
        {:put_tuple2, {:x, 1}, {:list, [{:atom, :heir}, {:atom, :none}]}},
        {:put_list, {:x, 1}, nil, {:x, 0}},
        {:call_ext, 2, {:extfunc, :ets, :new, 2}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, [{:heir, :none}]}
    end

    test "resolves typed register destination" do
      instrs = [
        {:move, {:atom, :hello}, {:tr, {:x, 0}, {:t_atom, [:hello]}}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, :hello}
    end

    test "returns :dynamic for bif result" do
      instrs = [
        {:bif, :self, :nofail, [], {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :pid_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end

    test "returns :dynamic for unresolvable register" do
      instrs = [
        {:label, 5},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end

    test "resolves y-register" do
      instrs = [
        {:move, {:atom, :saved}, {:y, 0}},
        {:move, {:y, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, :saved}
    end

    test "resolves put_map_assoc from literal base" do
      # %{strategy: :one_for_one} built via put_map_assoc on empty literal map.
      instrs = [
        {:put_map_assoc, {:f, 0}, {:literal, %{}}, {:x, 0}, 1,
         {:list, [{:atom, :strategy}, {:atom, :one_for_one}]}},
        {:call_ext, 2, {:extfunc, Supervisor, :init, 2}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) ==
               {:ok, %{strategy: :one_for_one}}
    end

    test "resolves put_map_exact updating existing map" do
      # Updates a literal base map with a new key.
      instrs = [
        {:put_map_exact, {:f, 0}, {:literal, %{a: 1}}, {:x, 0}, 1,
         {:list, [{:atom, :a}, {:integer, 2}]}},
        {:call_ext, 1, {:extfunc, :erlang, :map_size, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, %{a: 2}}
    end

    test "resolves put_map_assoc with multiple pairs" do
      instrs = [
        {:put_map_assoc, {:f, 0}, {:literal, %{}}, {:x, 1}, 2,
         {:list, [{:atom, :strategy}, {:atom, :one_for_one}, {:atom, :intensity}, {:integer, 5}]}},
        {:call_ext, 2, {:extfunc, Supervisor, :init, 2}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 1}) ==
               {:ok, %{strategy: :one_for_one, intensity: 5}}
    end

    test "returns :dynamic for gc_bif result" do
      instrs = [
        {:gc_bif, :byte_size, {:f, 0}, 1, [{:x, 0}], {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :integer_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end

    test "returns :dynamic for get_tuple_element with unresolvable source" do
      instrs = [
        {:get_tuple_element, {:x, 0}, 1, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end

    test "resolves get_tuple_element through literal" do
      instrs = [
        {:move, {:literal, {:ok, :value}}, {:x, 0}},
        {:get_tuple_element, {:x, 0}, 1, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, :value}
    end

    test "returns :dynamic for get_hd with unresolvable source" do
      instrs = [
        {:get_hd, {:x, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end

    test "resolves get_hd through literal" do
      instrs = [
        {:move, {:literal, [:first, :second]}, {:x, 0}},
        {:get_hd, {:x, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, :first}
    end

    test "returns :dynamic for get_tl with unresolvable source" do
      instrs = [
        {:get_tl, {:x, 0}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :erlang, :length, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 1}) == :dynamic
    end

    test "resolves get_tl through literal" do
      instrs = [
        {:move, {:literal, [:first, :second, :third]}, {:x, 0}},
        {:get_tl, {:x, 0}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :erlang, :length, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 1}) == {:ok, [:second, :third]}
    end

    test "returns :dynamic for local call writing to x0" do
      instrs = [
        {:call, 1, {:f, 15}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end

    test "returns :dynamic for preceding remote call writing to x0" do
      instrs = [
        {:call_ext, 1, {:extfunc, :erlang, :list_to_atom, 1}},
        {:move, {:x, 0}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      # Resolving x1 at idx 2 → follows move from x0 → hits call_ext at idx 0 → :dynamic.
      assert Helpers.resolve_register(instrs, 2, {:x, 1}) == :dynamic
    end

    test "does not return stale value past a gc_bif write" do
      # Without gc_bif in writes_to?, the resolver would skip past it and
      # find the earlier move, returning {:ok, :stale} — which is wrong.
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:gc_bif, :map_size, {:f, 0}, 1, [{:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :integer_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == :dynamic
    end

    test "does not return stale value past a get_tuple_element write" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:get_tuple_element, {:x, 1}, 0, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == :dynamic
    end

    test "resolves get_map_elements through literal map" do
      # %{strategy: strategy} = %{strategy: :one_for_one}
      instrs = [
        {:move, {:literal, %{strategy: :one_for_one, intensity: 5}}, {:x, 0}},
        {:get_map_elements, {:f, 0}, {:x, 0},
         {:list, [{:atom, :strategy}, {:x, 1}, {:atom, :intensity}, {:x, 2}]}},
        {:call_ext, 2, {:extfunc, Supervisor, :init, 2}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 1}) == {:ok, :one_for_one}
      assert Helpers.resolve_register(instrs, 2, {:x, 2}) == {:ok, 5}
    end

    test "returns :dynamic for get_map_elements with unresolvable source" do
      instrs = [
        {:get_map_elements, {:f, 0}, {:x, 0}, {:list, [{:atom, :strategy}, {:x, 1}]}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 1}) == :dynamic
    end

    test "does not return stale value past a get_map_elements write" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 1}},
        {:get_map_elements, {:f, 0}, {:x, 0}, {:list, [{:atom, :strategy}, {:x, 1}]}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 1}) == :dynamic
    end

    test "does not return stale value past a local call to x0" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:call, 0, {:f, 15}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == :dynamic
    end

    test "resolves swap by following the other register" do
      # swap x0, x1 — resolving x0 after swap means the value came from x1.
      instrs = [
        {:move, {:atom, :alpha}, {:x, 0}},
        {:move, {:atom, :beta}, {:x, 1}},
        {:swap, {:x, 0}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == {:ok, :beta}
      assert Helpers.resolve_register(instrs, 3, {:x, 1}) == {:ok, :alpha}
    end

    test "does not return stale value past a swap write" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:swap, {:x, 0}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      # x0 after swap came from x1, which has no preceding write → :dynamic.
      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == :dynamic
    end

    test "partially resolves structure with dynamic components" do
      # Tuple where second element is a bif result (dynamic).
      instrs = [
        {:bif, :self, :nofail, [], {:x, 1}},
        {:put_tuple2, {:x, 0}, {:list, [{:atom, :heir}, {:x, 1}, nil]}},
        {:call_ext, 1, {:extfunc, :erlang, :tuple_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, {:heir, :dynamic, nil}}
    end
  end
end
