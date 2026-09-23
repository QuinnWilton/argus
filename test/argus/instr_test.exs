defmodule Argus.InstrTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Argus.Instr
  alias Argus.Pipeline.{Disassemble, Emit, Normalize}

  describe "exhaustiveness" do
    # Every instruction the compilers in this toolchain produce: OTP's
    # applications, Elixir's, and every dependency in the build. An opcode
    # this module cannot read would otherwise pass as "writes nothing".
    @apps [:stdlib, :kernel, :compiler, :crypto, :ssl, :inets, :mnesia, :elixir, :logger] ++
            [:eex, :ex_unit, :mix, :iex]

    test "every instruction in OTP, Elixir and the dependencies is known, raw and normalized" do
      beams =
        Enum.flat_map(@apps, fn app ->
          case :code.lib_dir(app) do
            dir when is_list(dir) -> Path.wildcard(Path.join([to_string(dir), "ebin", "*.beam"]))
            {:error, :bad_name} -> []
          end
        end) ++ Path.wildcard(Path.join([Mix.Project.build_path(), "lib", "*", "ebin", "*.beam"]))

      assert length(beams) > 1000

      unknown =
        beams
        |> Task.async_stream(&unknown_in/1, ordered: false, timeout: :infinity)
        |> Enum.reduce(MapSet.new(), fn {:ok, found}, acc -> MapSet.union(acc, found) end)

      assert unknown == MapSet.new()
    end

    test "the debug markers of a beam_debug_info build are known" do
      {:ok, _mod, bin} =
        :compile.forms(erlang_forms("f(X) -> Y = X + 1, {ok, Y}."), [:beam_debug_info, :binary])

      assert unknown_in(bin) == MapSet.new()
    end

    test "an instruction it cannot read is unknown, and clobbers everything" do
      refute Instr.known?({:made_up, {:x, 0}})
      assert Instr.defs({:made_up, {:x, 0}}) == []
      assert Instr.clobbers?({:made_up, {:x, 0}}, {:y, 3})
      refute Instr.known?({:bs_match, {:f, 1}, {:x, 0}, {:commands, [{:new_command, 1}]}})
    end
  end

  describe "writes the operands do not name" do
    test "a try handler's try_case takes the exception in x0-x2" do
      assert Instr.defs({:try_case, {:y, 0}}) == [x: 0, x: 1, x: 2]
      assert Instr.uses({:try_case, {:y, 0}}) == [y: 0]
    end

    test "catch_end leaves the caught value in x0; build_stacktrace rewrites x0" do
      assert Instr.defs({:catch_end, {:y, 1}}) == [x: 0]
      # On the normal path x0 is the protected expression's own value.
      assert Instr.uses({:catch_end, {:y, 1}}) == [y: 1, x: 0]
      assert Instr.defs(:build_stacktrace) == [x: 0]
      assert Instr.uses(:build_stacktrace) == [x: 0]
    end

    test "trim renumbers the frame: it writes the low slots from the high ones" do
      trim = {:trim, 2, 2}
      assert Instr.defs(trim) == [y: 0, y: 1]
      assert Instr.uses(trim) == [y: 2, y: 3]
      assert Instr.copy_source(trim, {:y, 1}) == {:y, 3}
      assert Instr.copy_source(trim, {:y, 2}) == nil
      assert Instr.defs({:trim, 1, 0}) == []
    end

    test "a call writes x0 and destroys the other x registers, but not the y registers" do
      call = {:call_ext, 1, {:extfunc, :m, :f, 1}}
      assert Instr.defs(call) == [x: 0]
      assert Instr.uses(call) == [x: 0]
      assert Instr.clobbers?(call, {:x, 3})
      refute Instr.clobbers?(call, {:y, 0})
      assert Instr.uses({:call_fun, 2}) == [x: 0, x: 1, x: 2]
      assert Instr.uses({:apply, 1}) == [x: 0, x: 1, x: 2]
    end
  end

  describe "writes the walkers used to miss" do
    test "each writer names its destination" do
      for {instr, dsts} <- [
            {{:loop_rec, {:f, 3}, {:x, 0}}, [x: 0]},
            {{:get_list, {:x, 0}, {:x, 1}, {:x, 0}}, [x: 1, x: 0]},
            {{:make_fun3, {:m, :"-f/0-fun-0-", 1}, 0, 1, {:x, 2}, {:list, [y: 0]}}, [x: 2]},
            {{:init_yregs, {:list, [y: 0, y: 2]}}, [y: 0, y: 2]},
            {{:put_map_assoc, {:f, 0}, {:x, 0}, {:x, 1}, 2, {:list, [atom: :a, x: 3]}}, [x: 1]},
            {{:bs_create_bin, {:f, 0}, 0, 1, 1, {:x, 1}, {:list, []}}, [x: 1]},
            {{:bs_start_match4, {:atom, :no_fail}, 1, {:x, 0}, {:x, 2}}, [x: 2]},
            {{:bs_get_tail, {:x, 1}, {:y, 0}, 2}, [y: 0]},
            {{:test, :bs_start_match3, {:f, 5}, 1, [x: 0], {:x, 1}}, [x: 1]},
            {{:test, :bs_get_utf8, {:f, 5},
              [{:tr, {:x, 1}, :any}, 2, {:field_flags, []}, {:x, 3}]}, [x: 3]},
            {{:recv_marker_reserve, {:y, 0}}, [y: 0]}
          ] do
        assert Instr.defs(instr) == dsts, inspect(instr)
      end
    end

    test "a bs_match defines what its extracting commands name and reads the context" do
      match =
        {:bs_match, {:f, 9}, {:x, 1},
         {:commands,
          [
            {:ensure_at_least, 8, 1},
            {:integer, 2, {:literal, []}, 8, 1, {:x, 0}},
            {:skip, 8},
            {:get_tail, 2, 1, {:y, 1}}
          ]}}

      assert Instr.defs(match) == [x: 0, y: 1]
      assert Instr.uses(match) == [x: 1]
      assert Instr.targets(match) == [9]
    end

    test "map keys held in registers are read" do
      get =
        {:get_map_elements, {:f, 4}, {:x, 0}, {:list, [{:x, 5}, {:x, 1}, {:atom, :a}, {:x, 2}]}}

      assert Instr.defs(get) == [x: 1, x: 2]
      assert Instr.uses(get) == [x: 0, x: 5]
    end

    test "typed registers read as plain ones and literals are never looked into" do
      assert Instr.uses({:move, {:tr, {:x, 1}, {:t_atom, :any}}, {:x, 0}}) == [x: 1]
      assert Instr.uses({:move, {:literal, [x: 0]}, {:x, 0}}) == []
      assert Instr.defines?({:move, {:x, 1}, {:tr, {:x, 0}, :any}}, {:x, 0})
    end
  end

  describe "carry/2" do
    test "a value follows its copies and leaves the registers written over it" do
      assert Instr.carry({:move, {:x, 0}, {:y, 1}}, x: 0) == [x: 0, y: 1]
      assert Instr.carry({:move, {:atom, :a}, {:x, 0}}, x: 0, y: 1) == [y: 1]
      assert Instr.carry({:swap, {:x, 0}, {:y, 0}}, x: 0) == [y: 0]
      assert Instr.carry({:trim, 1, 1}, y: 1) == [y: 0]
      assert Instr.carry({:trim, 1, 1}, y: 0, x: 0) == [x: 0]
      assert Instr.carry({:deallocate, 2}, y: 1, x: 0) == [x: 0]
      assert Instr.carry({:put_tuple2, {:x, 0}, {:list, [x: 0]}}, x: 0) == []
    end

    test "a call destroys the x registers holding it, not the y registers" do
      assert Instr.carry({:call_ext, 1, {:extfunc, :m, :f, 1}}, x: 1, y: 0) == [y: 0]
      assert Instr.carry({:get_list, {:x, 2}, {:x, 0}, {:x, 1}}, x: 0, x: 3) == [x: 3]
    end
  end

  describe "control" do
    test "every label control can reach other than by falling through" do
      for {instr, labels} <- [
            {{:loop_rec, {:f, 3}, {:x, 0}}, [3]},
            {{:wait, {:f, 2}}, [2]},
            {{:wait_timeout, {:f, 2}, {:integer, 100}}, [2]},
            {{:loop_rec_end, {:f, 2}}, [2]},
            {{:bif, :map_get, {:f, 7}, [x: 0, x: 1], {:x, 2}}, [7]},
            {{:bif, :self, :nofail, [], {:x, 0}}, []},
            {{:gc_bif, :length, {:f, 8}, 1, [x: 0], {:x, 0}}, [8]},
            {{:get_map_elements, {:f, 4}, {:x, 0}, {:list, [atom: :a, x: 1]}}, [4]},
            {{:put_map_exact, {:f, 6}, {:x, 0}, {:x, 0}, 1, {:list, [atom: :a, x: 1]}}, [6]},
            {{:bs_start_match4, {:f, 11}, 1, {:x, 0}, {:x, 0}}, [11]},
            {{:try, {:y, 0}, {:f, 12}}, [12]},
            {{:catch, {:y, 0}, {:f, 13}}, [13]},
            {{:select_val, {:x, 0}, {:f, 5}, {:list, [atom: :a, f: 6, atom: :b, f: 7]}},
             [5, 6, 7]},
            {{:test, :is_eq_exact, {:f, 0}, [x: 0, atom: :a]}, []},
            {{:make_fun3, {:f, 20}, 0, 1, {:x, 0}, {:list, []}}, []}
          ] do
        assert Instr.targets(instr) == labels, inspect(instr)
      end
    end

    test "control goes on past a test or a call, and not past a transfer or a raise" do
      for instr <- [{:test, :is_atom, {:f, 3}, [x: 0]}, {:call, 1, {:m, :f, 1}}, :send] do
        assert Instr.falls_through?(instr), inspect(instr)
      end

      # erlang:raise/3 inline: an invalid class returns badarg in x0.
      assert Instr.falls_through?(:raw_raise)
      assert Instr.defs(:raw_raise) == [x: 0]

      for instr <- [
            {:jump, {:f, 1}},
            {:select_val, {:x, 0}, {:f, 5}, {:list, []}},
            {:wait, {:f, 2}},
            {:loop_rec_end, {:f, 2}},
            {:func_info, {:atom, :m}, {:atom, :f}, 0},
            {:badmatch, {:x, 0}},
            {:case_end, {:x, 0}},
            :if_end,
            {:try_case_end, {:x, 0}},
            {:bif, :raise, {:f, 0}, [x: 2, x: 1], {:x, 0}},
            :return,
            {:call_only, 1, {:m, :f, 1}},
            {:call_ext_last, 1, {:extfunc, :m, :f, 1}, 1}
          ] do
        refute Instr.falls_through?(instr), inspect(instr)
      end

      assert Instr.exits?(:return)
      assert Instr.exits?({:apply_last, 1, 0})
      refute Instr.exits?({:jump, {:f, 1}})
    end
  end

  describe "the emitter" do
    @modules [:lists, :gen_server, :proc_lib, :beam_ssa_codegen, Enum, GenServer, Kernel.Utils]

    property "records exactly Instr's reads, writes, fall-through and targets" do
      functions =
        for mod <- @modules,
            {:ok, data} = Disassemble.disassemble_path(to_string(:code.which(mod))),
            function <- data.functions,
            do: {mod, function}

      check all({mod, function} <- member_of(functions), max_runs: 200) do
        facts = Emit.emit_module(mod, [], [], [], [function])
        normalized = Normalize.normalize_function(mod, function)
        last = normalized |> List.last() |> elem(0)

        for {id, instr} <- normalized do
          assert rows(facts, :def, id) == spell(Instr.defs(instr)), inspect(instr)
          assert rows(facts, :use, id) == spell(Instr.uses(instr)), inspect(instr)
          assert labels(facts, id) == Enum.sort(Instr.targets(instr)), inspect(instr)

          assert Enum.any?(facts[:next] || [], &match?([^id, _], &1)) ==
                   (Instr.falls_through?(instr) and id != last),
                 inspect(instr)
        end
      end
    end
  end

  # --- helpers ------------------------------------------------------------

  defp unknown_in(beam) do
    case Disassemble.disassemble_path(beam) do
      {:ok, %{module: mod, functions: functions}} ->
        for {:function, _name, _arity, _entry, instrs} = function <- functions,
            instr <- instrs ++ Enum.map(Normalize.normalize_function(mod, function), &elem(&1, 1)),
            not Instr.known?(instr),
            into: MapSet.new(),
            do: instr

      {:error, _reason} ->
        MapSet.new()
    end
  end

  defp erlang_forms(body) do
    ("-module(instr_debug_probe).\n-export([f/1]).\n" <> body)
    |> String.to_charlist()
    |> :erl_scan.string()
    |> then(fn {:ok, tokens, _end} -> tokens end)
    |> Enum.chunk_while(
      [],
      fn
        {:dot, _} = dot, acc -> {:cont, Enum.reverse([dot | acc]), []}
        token, acc -> {:cont, [token | acc]}
      end,
      fn acc -> {:cont, acc} end
    )
    |> Enum.map(fn tokens ->
      {:ok, form} = :erl_parse.parse_form(tokens)
      form
    end)
  end

  defp rows(facts, relation, id) do
    Enum.sort(for [^id, reg] <- Map.get(facts, relation, []), do: reg)
  end

  # The labels the emitter's control facts send `id` to, besides falling
  # through; 0 is "no label" in every fail column.
  defp labels(facts, id) do
    for(
      {rel, pick} <- label_columns(),
      row <- Map.get(facts, rel, []),
      hd(row) == id,
      do: pick.(row)
    )
    |> Enum.map(&String.to_integer/1)
    |> Enum.reject(&(&1 == 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp label_columns do
    [
      {:jump, fn [_id, target] -> target end},
      {:branch, fn [_id, fail, _] -> fail end},
      {:select_branch, fn [_id, _val, target] -> target end},
      {:bif_call, fn [_id, _func, _mod, _name, _arity, fail] -> fail end},
      {:bs_start, fn [_id, fail] -> fail end},
      {:try_start, fn [_id, _func, _kind, handler] -> handler end}
    ]
  end

  defp spell(regs), do: regs |> Enum.map(fn {kind, n} -> "#{kind}#{n}" end) |> Enum.sort()
end
