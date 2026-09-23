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

  describe "imprecision tracing" do
    # Each ExUnit test runs in its own process, so the process dictionary
    # state is naturally isolated — no need to setup/teardown the flag.

    @ctx %{func_id: "MyMod:my_func/1", instrs: [], idx: 0}

    test "tracing is disabled by default" do
      refute Helpers.tracing_enabled?()
    end

    test "enable_tracing flips the flag for the current process only" do
      Helpers.enable_tracing()
      assert Helpers.tracing_enabled?()

      # Spawn another process and confirm it doesn't see this process's flag.
      parent = self()

      spawn(fn ->
        send(parent, {:other, Helpers.tracing_enabled?()})
      end)

      assert_receive {:other, false}, 1000
    end

    test "disable_tracing clears the flag" do
      Helpers.enable_tracing()
      assert Helpers.tracing_enabled?()

      Helpers.disable_tracing()
      refute Helpers.tracing_enabled?()
    end

    test "track_imprecision is a no-op when tracing is disabled" do
      facts = %{existing: [["row"]]}
      result = Helpers.track_imprecision(facts, @ctx, :test_category, :test_relation)
      assert result == facts
      refute Map.has_key?(result, :imprecision)
    end

    test "track_imprecision emits a fact when tracing is enabled" do
      Helpers.enable_tracing()

      result = Helpers.track_imprecision(%{}, @ctx, :test_category, :test_relation, :dynamic)

      assert result == %{
               imprecision: [
                 ["test_category", "MyMod:my_func/1", "test_relation", "dynamic"]
               ]
             }
    end

    test "track_imprecision uses the explicit reason argument" do
      Helpers.enable_tracing()

      result =
        Helpers.track_imprecision(%{}, @ctx, :supervisor_child, :supervisor_child, :skipped)

      assert result == %{
               imprecision: [
                 ["supervisor_child", "MyMod:my_func/1", "supervisor_child", "skipped"]
               ]
             }
    end

    test "track_dynamic is a no-op on concrete values even when tracing is enabled" do
      Helpers.enable_tracing()

      assert Helpers.track_dynamic(%{}, "MyServer", @ctx, :genserver_callee, :sync_call) == %{}
      assert Helpers.track_dynamic(%{}, ":foo", @ctx, :ets_table_name, :ets_new) == %{}
      assert Helpers.track_dynamic(%{}, {:arg, 0}, @ctx, :delayed_target, :delayed_message) == %{}
    end

    test "track_dynamic emits a fact for the string \"dynamic\"" do
      Helpers.enable_tracing()

      result = Helpers.track_dynamic(%{}, "dynamic", @ctx, :genserver_callee, :sync_call)

      assert result == %{
               imprecision: [
                 ["genserver_callee", "MyMod:my_func/1", "sync_call", "dynamic"]
               ]
             }
    end

    test "track_dynamic emits a fact for the atom :dynamic" do
      Helpers.enable_tracing()

      result = Helpers.track_dynamic(%{}, :dynamic, @ctx, :genserver_callee, :sync_call)

      assert result.imprecision == [
               ["genserver_callee", "MyMod:my_func/1", "sync_call", "dynamic"]
             ]
    end

    test "track_dynamic is a no-op when tracing is disabled even for dynamic values" do
      result = Helpers.track_dynamic(%{}, "dynamic", @ctx, :genserver_callee, :sync_call)
      assert result == %{}
    end

    test "multiple track_dynamic calls accumulate" do
      Helpers.enable_tracing()

      facts =
        %{}
        |> Helpers.track_dynamic("dynamic", @ctx, :cat_a, :rel_a)
        |> Helpers.track_dynamic("dynamic", @ctx, :cat_b, :rel_b)
        |> Helpers.track_dynamic("MyServer", @ctx, :cat_c, :rel_c)

      # Two events for the dynamic categories, one no-op for the concrete one.
      assert length(facts.imprecision) == 2
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
      # Tuple where second element is a bif result (dynamic). A `nil`
      # operand is BEAM assembly's empty list; the atom is `{:atom, nil}`.
      instrs = [
        {:bif, :self, :nofail, [], {:x, 1}},
        {:put_tuple2, {:x, 0}, {:list, [{:atom, :heir}, {:x, 1}, nil]}},
        {:call_ext, 1, {:extfunc, :erlang, :tuple_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == {:ok, {:heir, :dynamic, []}}
    end

    test "stops at return barrier instead of picking up stale value" do
      # Simulates multi-clause bytecode: clause 1 sets x0 = :ok then returns,
      # clause 2 code follows. Without barrier detection, the resolver crosses
      # the return and finds :ok.
      instrs = [
        {:move, {:atom, :ok}, {:x, 0}},
        :return,
        {:label, 7},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == :dynamic
    end

    test "stops at call_only barrier" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:call_only, 1, {:f, 20}},
        {:label, 8},
        {:call_ext, 1, {:extfunc, :ets, :lookup, 2}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == :dynamic
    end

    test "stops at call_ext_only barrier" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:call_ext_only, 1, {:extfunc, :erlang, :error, 1}},
        {:label, 9},
        {:call_ext, 1, {:extfunc, :ets, :lookup, 2}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == :dynamic
    end

    test "stops at call_last barrier" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:call_last, 1, {:f, 30}, 2},
        {:label, 10},
        {:call_ext, 1, {:extfunc, :ets, :lookup, 2}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == :dynamic
    end

    test "stops at call_ext_last barrier" do
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:call_ext_last, 1, {:extfunc, :erlang, :error, 1}, 2},
        {:label, 11},
        {:call_ext, 1, {:extfunc, :ets, :lookup, 2}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == :dynamic
    end

    test "barrier does not affect resolution within the same execution path" do
      # The write to x0 is AFTER the barrier (closer to the call site),
      # so the barrier is never reached.
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        :return,
        {:label, 7},
        {:move, {:atom, :fresh}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :erlang, :atom_to_list, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == {:ok, :fresh}
    end

    test "barrier stops indirect resolution through y-register" do
      # The y0 save is before the return barrier (different clause), so
      # tracing x0 → y0 → x0 should hit the barrier and return :dynamic.
      instrs = [
        {:move, {:atom, :stale}, {:x, 0}},
        {:move, {:x, 0}, {:y, 0}},
        :return,
        {:label, 7},
        {:move, {:y, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :ets, :lookup, 2}}
      ]

      assert Helpers.resolve_register(instrs, 5, {:x, 0}) == :dynamic
    end

    test "resolve_register stays :dynamic for unwritten function parameters" do
      # Function-arg classification is via arg_position/3 — resolve_register
      # itself preserves its existing :dynamic-for-unknowns contract so that
      # downstream value-extractors (get_tuple_element, get_hd, etc.) don't
      # see marker shapes mixed in with literal values.
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :get}, 1},
        {:label, 1},
        {:call_ext, 1, {:extfunc, :erlang, :node, 0}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == :dynamic
    end
  end

  describe "spell/1" do
    test "is inspect's spelling when inspect spells the whole value" do
      for value <- [:ok, "bin", [1, 2], %{a: {1, 2}}, %URI{host: "h"}] do
        assert Helpers.spell(value) == inspect(value, structs: false)
      end
    end

    # An ETS key or a literal past inspect's bounds used to spell the same
    # as another, and the two joined as one identity.
    test "keys that differ past inspect's bounds have different identities" do
      long = String.duplicate("k", 5000)
      identity = &Helpers.key_identity([{:move, {:literal, &1}, {:x, 1}}], 1, {:x, 1})

      assert {"literal", a} = identity.(long)
      assert {"literal", b} = identity.(String.duplicate("k", 4999) <> "z")
      refute a == b
      assert identity.(long) == {"literal", a}
    end
  end

  describe "improper-safe walks" do
    test "proper_list?/1 accepts only lists that end in []" do
      assert Helpers.proper_list?([])
      assert Helpers.proper_list?([1, [2 | 3]])
      refute Helpers.proper_list?([1 | 2])
      refute Helpers.proper_list?([1, 2 | :tail])
      refute Helpers.proper_list?(:atom)
    end

    test "list_elements/1 reads nothing from an improper list" do
      assert Helpers.list_elements([1, 2]) == [1, 2]
      assert Helpers.list_elements([1 | 2]) == []
      assert Helpers.list_elements({1, 2}) == []
    end

    test "mentions?/2 walks improper lists" do
      instr = {:put_list, {:x, 1}, {:list, [{:atom, :a} | {:x, 3}]}, {:x, 2}}
      assert Helpers.mentions?(instr, &(&1 == {:x, 3}))
      refute Helpers.mentions?(instr, &(&1 == {:x, 4}))
    end

    # A literal `{:x, 1}` is data; counting it as the register made a
    # handle_call look as though it read `from`.
    test "mentions?/2 does not enter a literal's value" do
      instr = {:move, {:literal, {:x, 1}}, {:x, 0}}
      refute Helpers.mentions?(instr, &(&1 == {:x, 1}))
      assert Helpers.mentions?(instr, &(&1 == {:x, 0}))
      assert Helpers.mentions?(instr, &match?({:literal, _}, &1))
    end

    test "value_contains?/2 searches tuples, improper lists and maps" do
      assert Helpers.value_contains?([verify: :verify_none], &(&1 == :verify_none))
      assert Helpers.value_contains?(["x" | :verify_none], &(&1 == :verify_none))
      assert Helpers.value_contains?(%{opts: {:verify_none}}, &(&1 == :verify_none))
      refute Helpers.value_contains?(["x" | "y"], &(&1 == :verify_none))
    end

    # A struct is a map that need not implement Enumerable; sequin's
    # compile-time Ecto.Query literals raised here.
    test "value_contains?/2 searches a struct's fields" do
      assert Helpers.value_contains?(%URI{host: :verify_none}, &(&1 == :verify_none))
      refute Helpers.value_contains?(%URI{}, &(&1 == :verify_none))
    end

    test "attribute_values/2 flattens entries and keeps an improper list whole" do
      attrs = [behaviour: [GenServer], odd: [:a | :b], behaviour: [[Supervisor]], odd: [:c]]
      assert Helpers.attribute_values(attrs, :behaviour) == [GenServer, Supervisor]
      assert Helpers.attribute_values(attrs, :odd) == [[:a | :b], :c]
    end
  end

  describe "resolve_register/3 — improper lists" do
    # Every consumer asking for a list raised on one; the call it was built
    # for raises at runtime too.
    test "an improper list resolves as unknown" do
      assert Helpers.resolve_register([{:move, {:literal, [:a | :b]}, {:x, 1}}], 1, {:x, 1}) ==
               :dynamic

      assert Helpers.resolve_register(
               [{:put_list, {:atom, :a}, {:atom, :b}, {:x, 1}}],
               1,
               {:x, 1}
             ) ==
               :dynamic
    end

    test "length/1 and ++ of an improper list are unknown" do
      length_of = [
        {:move, {:literal, [1 | 2]}, {:x, 0}},
        {:gc_bif, :length, {:f, 0}, 1, [{:x, 0}], {:x, 1}}
      ]

      assert Helpers.resolve_register(length_of, 2, {:x, 1}) == :dynamic

      append = [
        {:move, {:literal, [1 | 2]}, {:x, 0}},
        {:gc_bif, :++, {:f, 0}, 1, [{:x, 0}, {:literal, [3]}], {:x, 1}}
      ]

      assert Helpers.resolve_register(append, 2, {:x, 1}) == :dynamic
    end
  end

  describe "list_length/3" do
    test "counts the cons cells that built the list" do
      instrs = [
        {:put_list, {:x, 1}, nil, {:x, 2}},
        {:put_list, {:x, 0}, {:x, 2}, {:x, 2}},
        {:call_ext, 3, {:extfunc, :erlang, :apply, 3}}
      ]

      assert Helpers.list_length(instrs, 2, {:x, 2}) == 2
    end

    test "an unknown tail leaves the length unknown" do
      instrs = [{:put_list, {:x, 0}, {:x, 1}, {:x, 2}}]
      assert Helpers.list_length(instrs, 1, {:x, 2}) == nil
    end

    test "an improper tail, literal or built, has no length" do
      assert Helpers.list_length([{:move, {:literal, [:a | :b]}, {:x, 2}}], 1, {:x, 2}) == nil

      instrs = [{:put_list, {:atom, :a}, {:atom, :b}, {:x, 2}}]
      assert Helpers.list_length(instrs, 1, {:x, 2}) == nil
    end
  end

  describe "arg_position/3" do
    test "classifies x0 as parameter 0 for arity 1 functions" do
      # Mimics a tiny client wrapper: def get(pid), do: GenServer.call(pid, :get).
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :get}, 1},
        {:label, 1},
        {:move, {:atom, :get}, {:x, 1}},
        {:call_ext, 2, {:extfunc, GenServer, :call, 2}}
      ]

      assert Helpers.arg_position(instrs, 3, {:x, 0}) == {:ok, 0}
    end

    test "classifies x1 as parameter 1 for arity 2 functions" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :call_with_timeout}, 2},
        {:label, 1},
        {:move, {:atom, :ping}, {:x, 0}},
        {:call_ext, 2, {:extfunc, GenServer, :call, 2}}
      ]

      assert Helpers.arg_position(instrs, 3, {:x, 1}) == {:ok, 1}
    end

    test "returns :no for x register beyond arity" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :unary}, 1},
        {:label, 1},
        {:call_ext, 1, {:extfunc, :erlang, :node, 0}}
      ]

      assert Helpers.arg_position(instrs, 2, {:x, 2}) == :no
    end

    test "returns :no for y registers (never function parameters)" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 1},
        {:label, 1},
        {:call_ext, 1, {:extfunc, :erlang, :node, 0}}
      ]

      assert Helpers.arg_position(instrs, 2, {:y, 0}) == :no
    end

    test "handles {:tr, _, _} typed register input" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :get}, 1},
        {:label, 1},
        {:call_ext, 1, {:extfunc, :erlang, :node, 0}}
      ]

      assert Helpers.arg_position(instrs, 2, {:tr, {:x, 0}, :pid}) == {:ok, 0}
    end

    test "returns :no when the register has been written by the function body" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :get}, 1},
        {:label, 1},
        {:move, {:atom, :replaced}, {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      # x0 was rewritten by the move, so it's no longer the original parameter.
      assert Helpers.arg_position(instrs, 3, {:x, 0}) == :no
    end
  end

  describe "resolve_register/3 — call_field shape" do
    test "resolves get_tuple_element of remote call result to {:call_field, mfa, idx}" do
      # Mimics `{:ok, val} = File.read(path); use(val)`. We ask for the value
      # of x2 at the point of `use` — by then x2 has been written by the
      # get_tuple_element, so we walk back through it to the call.
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :read_file}, 1},
        {:label, 1},
        {:call_ext, 1, {:extfunc, File, :read, 1}},
        {:test, :is_tuple, {:f, 9}, [{:x, 0}]},
        {:test, :test_arity, {:f, 9}, [{:x, 0}, 2]},
        {:get_tuple_element, {:x, 0}, 1, {:x, 2}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 6, {:x, 2}) ==
               {:ok, {:call_field, "File:read/1", 1}}
    end

    test "a field of a call's field is unknown, not an element of the marker" do
      # `{:ok, {pid, _ref}} = GenServer.start_monitor(...)`: x2 is field 1
      # of the call's result and x3 is field 0 of that, which nothing names.
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :start}, 0},
        {:label, 1},
        {:call_ext, 3, {:extfunc, GenServer, :start_monitor, 3}},
        {:get_tuple_element, {:x, 0}, 1, {:x, 2}},
        {:get_tuple_element, {:x, 2}, 0, {:x, 3}},
        {:move, {:x, 3}, {:x, 0}},
        {:call_ext, 2, {:extfunc, GenServer, :call, 2}}
      ]

      assert Helpers.resolve_register(instrs, 6, {:x, 0}) == :dynamic
    end

    test "resolves field 0 (the :ok tag) the same way" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :start}, 0},
        {:label, 1},
        {:call_ext, 2, {:extfunc, GenServer, :start_link, 2}},
        {:test, :is_tuple, {:f, 9}, [{:x, 0}]},
        {:get_tuple_element, {:x, 0}, 0, {:x, 1}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 5, {:x, 1}) ==
               {:ok, {:call_field, "GenServer:start_link/2", 0}}
    end

    test "still resolves get_tuple_element of literal tuple to the literal element" do
      # Backward-compat: literal tuple resolution must still work.
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:literal, {:ok, :first, :second}}, {:x, 0}},
        {:get_tuple_element, {:x, 0}, 1, {:x, 1}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 1}) == {:ok, :first}
    end

    test "returns :dynamic when the source register has no remote-call writer" do
      # Source written by a local move from a parameter — not a call.
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 1},
        {:label, 1},
        {:get_tuple_element, {:x, 0}, 1, {:x, 1}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      # x0 is the function arg; get_tuple_element of an arg is :dynamic
      # because we don't know the arg's structure.
      assert Helpers.resolve_register(instrs, 3, {:x, 1}) == :dynamic
    end
  end

  describe "call_result_origin/3" do
    test "finds the call whose result the register holds, with its index" do
      instrs = [
        {:call_ext, 2, {:extfunc, :ets, :new, 2}},
        {:move, {:x, 0}, {:y, 0}},
        {:move, {:y, 0}, {:x, 0}},
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.call_result_origin(instrs, 3, {:x, 0}) == {:ok, {:ets, :new, 2}, 0}
    end

    test "follows y registers across intervening calls" do
      instrs = [
        {:call_ext, 2, {:extfunc, :ets, :new, 2}},
        {:move, {:x, 0}, {:y, 0}},
        {:call, 0, {SomeMod, :side_effect, 0}},
        {:move, {:y, 0}, {:x, 0}},
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.call_result_origin(instrs, 4, {:x, 0}) == {:ok, {:ets, :new, 2}, 0}
    end

    test "x registers other than x0 do not survive a call" do
      # x1 was set before the call, but calls clobber it — whatever x1
      # held at idx 2 is NOT the pre-call value.
      instrs = [
        {:move, {:atom, :tab}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :erlang, :self, 0}},
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.call_result_origin(instrs, 2, {:x, 1}) == :no
    end

    test "a literal move means the register is not a call result" do
      instrs = [
        {:move, {:atom, :my_table}, {:x, 0}},
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.call_result_origin(instrs, 1, {:x, 0}) == :no
    end

    test "stops at path barriers" do
      instrs = [
        {:call_ext, 2, {:extfunc, :ets, :new, 2}},
        :return,
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.call_result_origin(instrs, 2, {:x, 0}) == :no
    end

    test "reports a local (intra-module) call origin" do
      # `x0 = foreman(conf)` then used — a local `defp` helper the caller
      # may want to step into.
      instrs = [
        {:call, 1, {MyApp.Worker, :foreman, 1}},
        {:put_tuple2, {:x, 1}, {:list, [atom: MyApp.Child, x: 0]}},
        {:call_ext, 2, {:extfunc, DynamicSupervisor, :start_child, 2}}
      ]

      assert Helpers.call_result_origin(instrs, 2, {:x, 0}) ==
               {:ok, {MyApp.Worker, :foreman, 1}, 0}
    end
  end

  describe "recent_writer/3" do
    test "returns the most recent writer instruction and its index" do
      instrs = [
        {:move, {:atom, :a}, {:x, 0}},
        {:move, {:atom, :b}, {:x, 0}}
      ]

      assert Helpers.recent_writer(instrs, 2, {:x, 0}) == {:ok, {:move, {:atom, :b}, {:x, 0}}, 1}
    end

    test "returns a put_list writer without following the move chain" do
      instrs = [
        {:put_list, {:x, 1}, nil, {:x, 0}},
        {:call_ext, 1, {:extfunc, Foo, :bar, 1}}
      ]

      assert Helpers.recent_writer(instrs, 1, {:x, 0}) ==
               {:ok, {:put_list, {:x, 1}, nil, {:x, 0}}, 0}
    end

    test "a call is the writer of its x0 result" do
      instrs = [{:call_ext, 1, {:extfunc, Foo, :bar, 1}}, {:move, {:x, 0}, {:x, 1}}]
      assert {:ok, {:call_ext, 1, _}, 0} = Helpers.recent_writer(instrs, 1, {:x, 0})
    end

    test "a non-x0 x register does not survive a call" do
      instrs = [
        {:move, {:atom, :v}, {:x, 1}},
        {:call_ext, 0, {:extfunc, Foo, :bar, 0}}
      ]

      assert Helpers.recent_writer(instrs, 2, {:x, 1}) == :no
    end

    test "stops at path barriers" do
      instrs = [{:move, {:atom, :v}, {:x, 0}}, :return]
      assert Helpers.recent_writer(instrs, 2, {:x, 0}) == :no
    end
  end

  describe "tuple_element_identity/4 across a join" do
    # The arms of a `case` each build the record a Mnesia write takes:
    # its table and key agree across them, its other fields need not.
    defp record_arms(key_b) do
      [
        {:label, 1},
        {:func_info, {:atom, :m}, {:atom, :f}, 2},
        {:label, 2},
        {:allocate, 1, 2},
        {:move, {:x, 0}, {:y, 0}},
        {:test, :is_atom, {:f, 3}, [x: 1]},
        {:put_tuple2, {:x, 0}, {:list, [{:atom, :t}, {:y, 0}, {:atom, :a}]}},
        {:jump, {:f, 4}},
        {:label, 3},
        {:put_tuple2, {:x, 0}, {:list, [{:atom, :t}, key_b, {:atom, :b}]}},
        {:label, 4},
        {:call_ext, 1, {:extfunc, :mnesia, :dirty_write, 1}},
        {:deallocate, 1},
        :return
      ]
    end

    test "every writer agreeing on an element names it" do
      instrs = record_arms({:y, 0})
      assert Helpers.tuple_element_identity(instrs, 11, {:x, 0}, 0) == {"literal", ":t"}
      assert Helpers.tuple_element_identity(instrs, 11, {:x, 0}, 1) == {"param", "0"}
      assert Helpers.tuple_element_identity(instrs, 11, {:x, 0}, 2) == {"dynamic", ""}
    end

    test "writers that disagree name nothing" do
      instrs = record_arms({:atom, :other})
      assert Helpers.tuple_element_identity(instrs, 11, {:x, 0}, 1) == {"dynamic", ""}
    end
  end

  describe "trace/5" do
    test "follows copies, lets the answer follow a projection, and keeps what every path agrees on" do
      instrs = [
        {:label, 1},
        {:func_info, {:atom, :m}, {:atom, :f}, 1},
        {:label, 2},
        {:call_ext, 0, {:extfunc, :m, :start, 0}},
        {:get_tuple_element, {:x, 0}, 1, {:x, 1}},
        {:move, {:x, 1}, {:y, 0}},
        {:move, {:y, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :m, :use, 1}}
      ]

      origin = fn
        {at, {:get_tuple_element, src, _, _}}, follow -> follow.(at, src)
        {_at, {:call_ext, _, {:extfunc, m, f, a}}}, _follow -> {m, f, a}
        _writer, _follow -> nil
      end

      assert Helpers.trace(instrs, 7, {:x, 0}, nil, origin) == {:m, :start, 0}
      assert Helpers.trace(instrs, 3, {:x, 0}, nil, fn w, _ -> w end) == {:param, 0}
    end
  end

  describe "copy_read/2" do
    test "a copy's write comes from the one register it copied" do
      assert Helpers.copy_read({:move, {:y, 2}, {:x, 0}}, "x0") == "y2"
      assert Helpers.copy_read({:swap, {:x, 0}, {:y, 1}}, "y1") == "x0"
      assert Helpers.copy_read({:trim, 2, 3}, "y1") == "y3"
      assert Helpers.copy_read({:move, {:atom, :a}, {:x, 0}}, "x0") == nil
      assert Helpers.copy_read({:move, {:y, 2}, {:x, 0}}, "x1") == nil
    end
  end

  describe "tuple_element_identity/4" do
    test "an element of a tuple built just before is identified on its own" do
      instrs = [
        {:put_tuple2, {:x, 1}, {:list, [{:atom, :counters}, {:atom, :hits}, {:integer, 1}]}},
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.tuple_element_identity(instrs, 1, {:x, 1}, 0) == {"literal", ":counters"}
      assert Helpers.tuple_element_identity(instrs, 1, {:x, 1}, 1) == {"literal", ":hits"}
      assert Helpers.tuple_element_identity(instrs, 1, {:x, 1}, 2) == {"literal", "1"}
    end

    test "the tuple is followed through a move" do
      instrs = [
        {:put_tuple2, {:x, 2}, {:list, [{:atom, :k}, {:x, 0}]}},
        {:move, {:x, 2}, {:x, 1}},
        {:call_ext, 2, {:extfunc, :ets, :insert, 2}}
      ]

      assert Helpers.tuple_element_identity(instrs, 2, {:x, 1}, 0) == {"literal", ":k"}
    end

    test "a literal tuple, and one too short" do
      instrs = [{:move, {:literal, {:t, :key}}, {:x, 0}}, {:call_ext, 1, {:extfunc, M, :f, 1}}]

      assert Helpers.tuple_element_identity(instrs, 1, {:x, 0}, 1) == {"literal", ":key"}
      assert Helpers.tuple_element_identity(instrs, 1, {:x, 0}, 2) == {"dynamic", ""}
    end

    test "a tuple the function was handed says nothing about its elements" do
      instrs = [{:call_ext, 1, {:extfunc, M, :f, 1}}]
      assert Helpers.tuple_element_identity(instrs, 0, {:x, 0}, 0) == {"dynamic", ""}
    end
  end

  describe "keyword_value_register/4" do
    test "finds the value register of a runtime-built keyword pair" do
      # opts = [name: <y0>] built as a cons of a {:name, y0} tuple.
      instrs = [
        {:call_ext, 2, {:extfunc, MyApp.Registry, :via, 2}},
        {:move, {:x, 0}, {:y, 0}},
        {:put_tuple2, {:x, 1}, {:list, [atom: :name, y: 0]}},
        {:put_list, {:x, 1}, nil, {:x, 1}},
        {:put_tuple2, {:x, 0}, {:list, [atom: MyApp.Child, x: 1]}},
        {:call_ext, 2, {:extfunc, Supervisor, :init, 2}}
      ]

      # The child tuple is at idx 4; its opts operand is x1.
      assert Helpers.keyword_value_register(instrs, 4, {:x, 1}, :name) == {:ok, {:y, 0}, 2}
    end

    test "walks past a non-matching leading pair to a later key" do
      # opts = [conf: y1, name: y0]
      instrs = [
        {:put_tuple2, {:x, 1}, {:list, [atom: :name, y: 0]}},
        {:put_list, {:x, 1}, nil, {:x, 1}},
        {:put_tuple2, {:x, 2}, {:list, [atom: :conf, y: 1]}},
        {:put_list, {:x, 2}, {:x, 1}, {:x, 0}},
        {:move, {:atom, :sentinel}, {:x, 3}}
      ]

      assert Helpers.keyword_value_register(instrs, 4, {:x, 0}, :name) == {:ok, {:y, 0}, 0}
    end

    test "returns :no when the key's value is a literal (no register)" do
      instrs = [
        {:put_tuple2, {:x, 1}, {:list, [atom: :name, atom: :static]}},
        {:put_list, {:x, 1}, nil, {:x, 0}},
        {:move, {:atom, :sentinel}, {:x, 2}}
      ]

      assert Helpers.keyword_value_register(instrs, 2, {:x, 0}, :name) == :no
    end

    test "returns :no when the key is absent" do
      instrs = [
        {:put_tuple2, {:x, 1}, {:list, [atom: :conf, y: 1]}},
        {:put_list, {:x, 1}, nil, {:x, 0}},
        {:move, {:atom, :sentinel}, {:x, 2}}
      ]

      assert Helpers.keyword_value_register(instrs, 2, {:x, 0}, :name) == :no
    end
  end

  describe "resolve_register/3 — placeholder normalization" do
    test "top-level :dynamic placeholder is unresolved, not a value" do
      # x1 = [<unknown>], x0 = hd(x1). The list resolves partially with
      # the :dynamic placeholder as its head, so hd surfaces the
      # placeholder itself — that's "unresolved", never {:ok, :dynamic}
      # (which inspect/1 would forge into a ":dynamic" fact field).
      instrs = [
        {:put_list, {:x, 9}, nil, {:x, 1}},
        {:bif, :hd, {:f, 0}, [{:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 0}) == :dynamic
    end

    test "placeholders nested inside structures still pass through" do
      instrs = [
        {:put_list, {:x, 9}, nil, {:x, 1}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 1}) == {:ok, [:dynamic]}
    end

    test "a literal :dynamic atom is indistinguishable from the placeholder" do
      # Deliberate: the "dynamic" string is the pipeline-wide unknown
      # marker, so a module literally using the atom :dynamic reads as
      # unresolved rather than forging a distinct ":dynamic" field.
      instrs = [
        {:move, {:atom, :dynamic}, {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == :dynamic
    end
  end

  describe "resolve_register/3 — pure BIF whitelist" do
    test "resolves :erlang.element/2 of a literal tuple" do
      # x0 = elem({:a, :b, :c}, 2) => :b. Compiles to a `bif element` with
      # the tuple in x1 (or as a literal operand) and index 2.
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:literal, {:a, :b, :c}}, {:x, 1}},
        {:bif, :element, {:f, 0}, [{:integer, 2}, {:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == {:ok, :b}
    end

    test "resolves :erlang.tuple_size/1 of a literal tuple" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:literal, {:a, :b, :c}}, {:x, 1}},
        {:bif, :tuple_size, {:f, 0}, [{:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == {:ok, 3}
    end

    test "resolves :erlang.length/1 (gc_bif) of a literal list" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:literal, [1, 2, 3, 4]}, {:x, 1}},
        {:gc_bif, :length, {:f, 0}, 1, [{:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == {:ok, 4}
    end

    test "resolves :erlang.atom_to_binary/1 of a literal atom" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:atom, :hello}, {:x, 1}},
        {:bif, :atom_to_binary, {:f, 0}, [{:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == {:ok, "hello"}
    end

    test "returns :dynamic when the BIF arg is not statically resolvable" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 1},
        {:label, 1},
        {:bif, :tuple_size, {:f, 0}, [{:x, 0}], {:x, 1}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      # x0 is the function parameter — we don't know its value,
      # so tuple_size(x0) is :dynamic.
      assert Helpers.resolve_register(instrs, 3, {:x, 1}) == :dynamic
    end

    test "returns :dynamic for non-whitelisted BIFs" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:bif, :phash2, {:f, 0}, [{:atom, :foo}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 3, {:x, 0}) == :dynamic
    end

    test "returns :dynamic when element index is out of range (no crash)" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:literal, {:a, :b}}, {:x, 1}},
        {:bif, :element, {:f, 0}, [{:integer, 99}, {:x, 1}], {:x, 0}},
        {:call_ext, 1, {:extfunc, IO, :inspect, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == :dynamic
    end
  end

  describe "resolve_to_arg_or_atom/3" do
    test "returns {:atom, _} for literal atoms" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:move, {:atom, MyServer}, {:x, 0}},
        {:call_ext, 1, {:extfunc, GenServer, :stop, 1}}
      ]

      assert Helpers.resolve_to_arg_or_atom(instrs, 3, {:x, 0}) == {:atom, "MyServer"}
    end

    test "returns {:arg, n} for function parameters" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :get}, 1},
        {:label, 1},
        {:call_ext, 1, {:extfunc, GenServer, :stop, 1}}
      ]

      assert Helpers.resolve_to_arg_or_atom(instrs, 2, {:x, 0}) == {:arg, 0}
    end

    test "returns :dynamic when value cannot be statically determined" do
      instrs = [
        {:func_info, {:atom, MyMod}, {:atom, :test}, 0},
        {:label, 1},
        {:call_ext, 0, {:extfunc, :erlang, :self, 0}},
        {:call_ext, 1, {:extfunc, GenServer, :stop, 1}}
      ]

      # x0 holds the result of :erlang.self() — call result is :dynamic.
      assert Helpers.resolve_to_arg_or_atom(instrs, 3, {:x, 0}) == :dynamic
    end
  end

  describe "walks follow the writes that reach, on real bytecode" do
    alias Argus.Test.Fixtures.Instr, as: Fixture

    defp function(name) do
      {:ok, data} =
        Argus.Pipeline.Disassemble.disassemble_path(to_string(:code.which(Fixture)))

      [instrs] = for {:function, ^name, _, _, instrs} <- data.functions, do: instrs
      instrs
    end

    defp call_to(instrs, fun) do
      Enum.find_index(instrs, &match?({_, 2, {:extfunc, GenServer, ^fun, 2}}, &1)) ||
        Enum.find_index(instrs, &match?({_, 2, {:extfunc, GenServer, ^fun, 2}, _}, &1))
    end

    test "a received message is loop_rec's write, not the parameter" do
      instrs = function(:recv)
      idx = call_to(instrs, :call)

      assert Helpers.arg_position(instrs, idx, {:x, 0}) == :no
      assert Helpers.resolve_to_arg_or_atom(instrs, idx, {:x, 0}) == :dynamic
      assert Helpers.key_identity(instrs, idx, {:x, 0}) == {"dynamic", ""}
    end

    test "a list's tail is get_list's write, not the parameter it came from" do
      instrs = function(:tailp)
      idx = call_to(instrs, :call)

      assert Helpers.arg_position(instrs, idx, {:x, 0}) == :no
      assert Helpers.key_identity(instrs, idx, {:x, 0}) == {"dynamic", ""}
    end

    test "a label reached only through a map match's fail edge is not the arm laid out before it" do
      instrs = function(:stale_arm)
      idx = call_to(instrs, :call)

      # Walking the stream read the first arm's `:stale`; x0 is `x`.
      assert Helpers.resolve_register(instrs, idx, {:x, 0}) == :dynamic
      assert Helpers.arg_position(instrs, idx, {:x, 0}) == {:ok, 1}
    end

    test "a rescue's reason is not a parameter" do
      instrs = function(:handler)
      idx = Enum.find_index(instrs, &match?({:try_case, _}, &1))

      assert Helpers.arg_position(instrs, idx + 1, {:x, 1}) == :no
      assert Helpers.arg_position(instrs, idx + 1, {:x, 0}) == :no
    end

    test "a value bound before a try reaches its handler, and both arms' atoms do not agree" do
      instrs = function(:fallback)
      tuple = Enum.find_index(instrs, &match?({:put_tuple2, _, {:list, [{:y, _}, _]}}, &1))
      {:put_tuple2, _, {:list, [y, _]}} = Enum.at(instrs, tuple)

      assert Helpers.resolve_register(instrs, tuple, y) == :dynamic

      assert [_, _] = Argus.Instr.Reaching.sources(instrs, tuple, y)
    end

    test "an x register does not survive a call" do
      instrs = [
        {:move, {:atom, :before}, {:x, 1}},
        {:call_ext, 1, {:extfunc, :m, :f, 1}},
        {:call_ext, 2, {:extfunc, :m, :g, 2}}
      ]

      assert Helpers.resolve_register(instrs, 2, {:x, 1}) == :dynamic
      assert Helpers.recent_writer(instrs, 2, {:x, 1}) == :no
    end

    test "the empty list is spelled nil and read as []" do
      instrs = [{:move, nil, {:x, 0}}, {:call_ext, 1, {:extfunc, :m, :f, 1}}]
      assert Helpers.resolve_register(instrs, 1, {:x, 0}) == {:ok, []}
      assert Helpers.list_length(instrs, 1, {:x, 0}) == 0
    end

    test "a trim renumbers the frame; a walk follows the slot that moved" do
      instrs = [
        {:move, {:atom, :kept}, {:y, 1}},
        {:move, {:atom, :dropped}, {:y, 0}},
        {:trim, 1, 1},
        {:move, {:y, 0}, {:x, 0}},
        {:call_ext, 1, {:extfunc, :m, :f, 1}}
      ]

      assert Helpers.resolve_register(instrs, 4, {:x, 0}) == {:ok, :kept}
    end
  end
end
