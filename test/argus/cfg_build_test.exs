defmodule Argus.CfgBuildTest do
  # In-process basic-block CFG construction. Fixtures are compiled here and
  # hand-checked; the structural properties at the bottom run over every
  # fixture plus a real stdlib module.
  use ExUnit.Case, async: false

  alias Argus.Cfg
  alias Argus.Cfg.Function

  defp cfg_for(source) do
    previous = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)
    [{module, beam} | _] = Code.compile_string(source, "nofile")
    Code.put_compiler_option(:debug_info, previous)

    dir = Path.join(System.tmp_dir!(), "argus_cfg_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{module}.beam")
    File.write!(path, beam)

    {:ok, typed} = Argus.Pipeline.extract([path], format: :typed)
    File.rm_rf!(dir)
    :code.purge(module)
    :code.delete(module)
    Cfg.build(typed)
  end

  test "a straight-line function is one returning block after the failure pad" do
    cfgs = cfg_for("defmodule CfgAdd do\n  def add(a, b), do: a + b\nend\n")
    fun = cfgs[{"add", 2}]

    entry = fun.blocks[fun.entry]
    assert entry.terminator == :return
    assert fun.rpo == [fun.entry]
    assert fun.loop_headers == MapSet.new()

    # The func_info failure pad never falls through and is unreachable here.
    pad = Enum.find_value(fun.blocks, fn {_id, b} -> if b.terminator == :raise, do: b end)
    assert pad
    refute pad.id in fun.rpo

    # block_at resolves an instruction index to its containing block.
    assert Function.block_at(fun, elem(pad.range, 0)).id == pad.id
  end

  test "if/else: a branch block fans out and the arms re-join at a merge" do
    # The arms feed a shared call, so the compiler can't duplicate the
    # continuation into each arm — a real merge block exists.
    cfgs =
      cfg_for("""
      defmodule CfgIf do
        def m(x) do
          y =
            if x > 0 do
              x + 1
            else
              x - 1
            end

          Integer.to_string(y)
        end
      end
      """)

    fun = cfgs[{"m", 1}]

    branch =
      Enum.find_value(fun.blocks, fn {_id, b} -> if b.terminator == :branch, do: b end)

    assert branch, "expected a conditional block"
    kinds = Enum.map(branch.succs, fn {_to, kind} -> kind end)
    assert :branch_fail in kinds and :branch_pass in kinds

    merge =
      Enum.find_value(fun.blocks, fn {_id, b} ->
        if length(b.preds) >= 2 and Enum.any?(b.preds, &match?({_, :jump}, &1)), do: b
      end)

    assert merge, "expected a merge block with a jump predecessor"

    # The branch block dominates both arms and the merge.
    assert Function.dominates?(fun, branch.id, merge.id)
    assert merge.id in Function.region(fun, branch.id)
  end

  test "a literal case compiles to a select with value-tagged arm edges" do
    cfgs =
      cfg_for("""
      defmodule CfgSel do
        def s(x) do
          case x do
            :a -> 1
            :b -> 2
            _ -> 3
          end
        end
      end
      """)

    fun = cfgs[{"s", 1}]

    assert [select] = fun.selects
    assert Map.keys(select.arms) |> Enum.sort() == [":a", ":b"]
    assert select.default != nil

    select_block = Function.block_at(fun, select.idx)
    assert select_block.terminator == :select

    arm_kinds = Enum.map(select_block.succs, fn {_to, kind} -> kind end)
    assert {:select_arm, ":a"} in arm_kinds
    assert :select_fail in arm_kinds
  end

  test "try/rescue: the protected block carries an exception edge to the handler" do
    cfgs =
      cfg_for("""
      defmodule CfgTry do
        def t(f) do
          f.()
        rescue
          _ -> :err
        end
      end
      """)

    fun = cfgs[{"t", 1}]

    installer =
      Enum.find_value(fun.blocks, fn {_id, b} -> if b.terminator == :exception, do: b end)

    assert installer, "expected a try_start block"
    assert [{handler, :exception}] = Enum.filter(installer.succs, &match?({_, :exception}, &1))
    assert handler in fun.rpo
  end

  test "a receive loop has a back edge and therefore a loop header" do
    cfgs =
      cfg_for("""
      defmodule CfgRecv do
        def await do
          receive do
            :stop -> :ok
            _other -> await()
          end
        end
      end
      """)

    fun = cfgs[{"await", 0}]
    assert MapSet.size(fun.loop_headers) >= 1

    # The header is reachable and genuinely dominated into itself via a cycle:
    # one of its predecessors is dominated by it.
    header = Enum.at(fun.loop_headers, 0)

    assert Enum.any?(fun.blocks[header].preds, fn {pred, _kind} ->
             Function.dominates?(fun, header, pred)
           end)
  end

  describe "structural invariants" do
    @fixtures [
      "defmodule CfgP1 do\n  def add(a, b), do: a + b\nend\n",
      """
      defmodule CfgP2 do
        def classify(x) do
          cond do
            x > 100 -> :big
            x > 0 -> :small
            true -> :neg
          end
        end
      end
      """,
      """
      defmodule CfgP3 do
        def sum([]), do: 0
        def sum([h | t]), do: h + sum(t)

        def fetch(map, key) do
          case Map.fetch(map, key) do
            {:ok, value} -> value
            :error -> nil
          end
        end
      end
      """
    ]

    test "blocks partition the instruction stream with no gaps or overlaps" do
      for fun <- all_functions() do
        ranges = fun.blocks |> Map.values() |> Enum.map(& &1.range) |> Enum.sort()
        n = ranges |> Enum.map(fn {_first, last} -> last end) |> Enum.max() |> Kernel.+(1)

        covered = Enum.flat_map(ranges, fn {first, last} -> Enum.to_list(first..last) end)
        assert covered == Enum.to_list(0..(n - 1)), "#{fun.func}/#{fun.arity} ranges broken"
      end
    end

    test "preds are exactly the inverse of succs, over existing blocks" do
      for fun <- all_functions() do
        succ_edges =
          for {from, block} <- fun.blocks, {to, kind} <- block.succs, do: {from, to, kind}

        pred_edges =
          for {to, block} <- fun.blocks, {from, kind} <- block.preds, do: {from, to, kind}

        assert Enum.sort(succ_edges) == Enum.sort(pred_edges), "#{fun.func}/#{fun.arity}"

        for {_from, to, _kind} <- succ_edges do
          assert Map.has_key?(fun.blocks, to)
        end
      end
    end

    test "the entry dominates every reachable block and idom forms a tree" do
      for fun <- all_functions(), block <- fun.rpo do
        assert Function.dominates?(fun, fun.entry, block),
               "#{fun.func}/#{fun.arity}: entry does not dominate #{block}"

        assert walks_to_entry?(fun, block, map_size(fun.blocks) + 1),
               "#{fun.func}/#{fun.arity}: idom chain from #{block} does not reach entry"
      end
    end

    test "every loop header is the target of a back edge from a block it dominates" do
      for fun <- all_functions(), header <- fun.loop_headers do
        assert Enum.any?(fun.blocks[header].preds, fn {pred, _kind} ->
                 Function.dominates?(fun, header, pred)
               end)
      end
    end

    defp all_functions do
      fixtures = Enum.flat_map(@fixtures, fn source -> Map.values(cfg_for(source)) end)

      {:ok, typed} =
        Argus.Pipeline.extract([to_string(:code.which(:lists))], format: :typed)

      fixtures ++ Map.values(Argus.Cfg.build(typed))
    end

    defp walks_to_entry?(fun, block, fuel)
    defp walks_to_entry?(_fun, _block, 0), do: false
    defp walks_to_entry?(%{entry: entry}, entry, _fuel), do: true

    defp walks_to_entry?(fun, block, fuel) do
      case Map.fetch(fun.idom, block) do
        {:ok, dom} -> walks_to_entry?(fun, dom, fuel - 1)
        :error -> false
      end
    end
  end
end
