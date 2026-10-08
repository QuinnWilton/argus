defmodule Argus.CfgBuildTest do
  # In-process basic-block CFG construction. Fixtures are compiled here and
  # hand-checked; the structural properties at the bottom run over every
  # fixture plus a real stdlib module.
  use ExUnit.Case, async: true

  alias Argus.Cfg
  alias Argus.Cfg.Function

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

  # The structural invariants' functions, built once: every fixture's,
  # :lists's, and a function of four hundred clauses.
  setup_all do
    %{functions: all_functions(), many_clauses: Map.values(cfg_for(many_clauses()))}
  end

  defp cfg_for(source) do
    [{module, beam} | _] = Code.compile_string(source, "nofile")

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

  test "completing_blocks: a test whose other side raises decides nothing; a branch does" do
    cfgs =
      cfg_for("""
      defmodule CfgCompleting do
        def head([]) do
          {:ok, x} = fetch()
          touch(x)
        end

        def branch(opt) do
          if opt, do: touch(:a)
          touch(:b)
        end

        def fetch, do: {:ok, 1}
        def touch(x), do: x
      end
      """)

    # head/1: its clause head and its badmatch fail into raising blocks;
    # every block the function can complete through runs on every start.
    head = cfgs[{"head", 1}]
    always = Function.completing_blocks(head)
    completing = for id <- head.rpo, head.blocks[id].terminator != :raise, do: id
    assert completing != [] and Enum.all?(completing, &(&1 in always))

    # branch/1: the `if` arm runs on some completing paths only.
    branch = cfgs[{"branch", 1}]
    always = Function.completing_blocks(branch)

    assert Enum.any?(branch.rpo, fn id ->
             branch.blocks[id].terminator != :raise and id not in always
           end)
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

  test "if/else: post-dominators and control dependence over the diamond" do
    cfgs =
      cfg_for("""
      defmodule CfgPdom do
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

    arms = Enum.map(branch.succs, fn {to, _kind} -> to end)

    merge =
      Enum.find_value(fun.blocks, fn {_id, b} ->
        if length(b.preds) >= 2 and Enum.any?(b.preds, &match?({_, :jump}, &1)), do: b
      end)

    # The merge post-dominates the branch and both arms; the arms
    # post-dominate nothing but themselves.
    assert Function.postdominates?(fun, merge.id, branch.id)
    assert Enum.all?(arms, &Function.postdominates?(fun, merge.id, &1))
    refute Enum.any?(arms, &Function.postdominates?(fun, &1, branch.id))

    # Each arm is control-dependent on the branch; the merge runs
    # regardless, so it is not.
    deps = Function.control_deps(fun)
    assert Enum.all?(arms, fn arm -> branch.id in Map.get(deps, arm, []) end)
    refute branch.id in Map.get(deps, merge.id, [])

    # The virtual exit is the terminal block's post-dominator (here the
    # merge tail-calls Integer.to_string, so the merge is terminal).
    terminal =
      Enum.find_value(fun.blocks, fn {_id, b} -> if b.succs == [] and b.id in fun.rpo, do: b end)

    assert fun.ipdom[terminal.id] == :exit
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

  describe "raises read as Argus.Instr reads them" do
    # One function of hand-written disassembly: `body` after the entry label.
    defp graph(body) do
      functions = [
        {:function, :f, 3, 2,
         [{:label, 1}, {:func_info, {:atom, :m}, {:atom, :f}, 3}, {:label, 2}] ++ body}
      ]

      Cfg.build_for(%{module: :m, functions: functions}, :f, 3)
    end

    defp terminator_of(fun, idx),
      do: Enum.find_value(fun.blocks, fn {_id, b} -> if elem(b.range, 1) == idx, do: b end)

    test "raw_raise falls through: an invalid class returns badarg to the code after it" do
      fun = graph([:raw_raise, {:move, {:atom, :ok}, {:x, 0}}, :return])

      entry = fun.blocks[fun.entry]
      assert entry.terminator == :return

      refute Enum.any?(fun.blocks, fn {_id, b} -> b.terminator == :raise and b.id == fun.entry end)
    end

    test "the raise BIF and badrecord end their block with no successor" do
      for raise <- [{:bif, :raise, {:f, 0}, [{:x, 2}, {:x, 1}], {:x, 0}}, {:badrecord, {:x, 0}}] do
        fun = graph([raise, {:move, {:atom, :ok}, {:x, 0}}, :return])
        block = terminator_of(fun, 3)

        assert block.terminator == :raise, "#{inspect(raise)} ends its block"
        assert block.succs == []
      end
    end

    test "apply_last leaves the function as a tail call" do
      fun = graph([{:apply_last, 1, 0}])
      assert fun.blocks[fun.entry].terminator == :tail_call
    end
  end

  describe "structural invariants" do
    test "blocks partition the instruction stream with no gaps or overlaps", %{functions: fs} do
      for fun <- fs do
        ranges = fun.blocks |> Map.values() |> Enum.map(& &1.range) |> Enum.sort()
        n = ranges |> Enum.map(fn {_first, last} -> last end) |> Enum.max() |> Kernel.+(1)

        covered = Enum.flat_map(ranges, fn {first, last} -> Enum.to_list(first..last) end)
        assert covered == Enum.to_list(0..(n - 1)), "#{fun.func}/#{fun.arity} ranges broken"
      end
    end

    test "preds are exactly the inverse of succs, over existing blocks", %{functions: fs} do
      for fun <- fs do
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

    test "idom and ipdom are the dominators the textbook fixpoint finds", ctx do
      for fun <- ctx.functions ++ ctx.many_clauses do
        succs = Map.new(fun.blocks, fn {id, b} -> {id, Enum.map(b.succs, &elem(&1, 0))} end)
        preds = Map.new(fun.blocks, fn {id, b} -> {id, Enum.map(b.preds, &elem(&1, 0))} end)
        assert fun.idom == textbook_idom(fun.entry, succs, preds), "#{fun.func}/#{fun.arity}"

        terminals = for {id, out} <- succs, out == [], do: id
        exit_succs = Map.put(preds, :exit, terminals)

        exit_preds =
          Enum.reduce(terminals, succs, &Map.update!(&2, &1, fn out -> [:exit | out] end))

        assert fun.ipdom == textbook_idom(:exit, exit_succs, exit_preds),
               "#{fun.func}/#{fun.arity}: ipdom"
      end
    end

    test "the loop headers are the targets of the edges whose target dominates their source",
         ctx do
      for fun <- ctx.functions ++ ctx.many_clauses do
        expected =
          for {from, block} <- fun.blocks,
              {to, _kind} <- block.succs,
              from in fun.rpo,
              Function.dominates?(fun, to, from),
              into: MapSet.new(),
              do: to

        assert fun.loop_headers == expected, "#{fun.func}/#{fun.arity}"
      end
    end

    test "block_at finds every instruction's block and nothing outside the function",
         %{functions: fs} do
      for fun <- fs do
        for {id, %{range: {first, last}}} <- fun.blocks, idx <- first..last do
          assert Function.block_at(fun, idx).id == id
        end

        last = fun.blocks |> Map.values() |> Enum.map(&elem(&1.range, 1)) |> Enum.max()
        assert Function.block_at(fun, last + 1) == nil
        assert Function.block_at(fun, -1) == nil
      end
    end

    # Every clause fails to the next and the last to one landing pad: a
    # dominator tree as deep as the function is long, which the solver
    # must neither recurse through nor walk once per predecessor.
    defp many_clauses do
      clauses = Enum.map_join(1..400, "\n", &"  def f(#{&1}, x), do: {:ok, x + #{&1}}")
      "defmodule CfgManyClauses do\n#{clauses}\n  def f(_n, x), do: x\nend\n"
    end

    # Dominator sets by the iterative intersection over predecessors,
    # from the root; a block's immediate dominator is the strict
    # dominator every other strict dominator dominates.
    defp textbook_idom(root, succs, preds) do
      reachable = reach([root], succs, MapSet.new())
      all = MapSet.to_list(reachable)

      doms =
        Map.new(all, fn b -> {b, if(b == root, do: MapSet.new([root]), else: reachable)} end)

      doms = dom_fixpoint(doms, all, root, preds, reachable)

      for b <- all, b != root, into: %{} do
        strict = MapSet.delete(doms[b], b)
        {b, Enum.find(strict, fn d -> MapSet.subset?(strict, doms[d]) end)}
      end
    end

    defp dom_fixpoint(doms, all, root, preds, reachable) do
      next =
        Map.new(all, fn
          ^root ->
            {root, doms[root]}

          b ->
            inter =
              preds
              |> Map.get(b, [])
              |> Enum.filter(&MapSet.member?(reachable, &1))
              |> Enum.map(&doms[&1])
              |> Enum.reduce(&MapSet.intersection/2)

            {b, MapSet.put(inter, b)}
        end)

      if next == doms, do: doms, else: dom_fixpoint(next, all, root, preds, reachable)
    end

    defp reach([], _succs, seen), do: seen

    defp reach([b | rest], succs, seen) do
      if MapSet.member?(seen, b),
        do: reach(rest, succs, seen),
        else: reach(Map.get(succs, b, []) ++ rest, succs, MapSet.put(seen, b))
    end

    defp all_functions do
      fixtures = Enum.flat_map(@fixtures, fn source -> Map.values(cfg_for(source)) end)

      {:ok, typed} =
        Argus.Pipeline.extract([to_string(:code.which(:lists))], format: :typed)

      fixtures ++ Map.values(Argus.Cfg.build(typed))
    end
  end
end
