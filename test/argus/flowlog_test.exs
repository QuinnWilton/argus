defmodule Argus.FlowLogTest do
  @moduledoc """
  argus's FlowLog engines on a small program of their own: what the tool
  says of a program, a one-shot solve, and an engine kept between
  commits — its deltas, how it refuses what it cannot apply, and that its
  OS process never outlives the port that owns it.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  @moduletag :flowlog
  # The engine for the program below is built once per version of argus's
  # toolchain; the first build compiles it.
  @moduletag timeout: 900_000

  alias Argus.FlowLog
  alias Argus.FlowLog.Engine

  @program """
  .decl edge(x: symbol, y: symbol) mutable
  .input edge
  .decl blocked(x: symbol) mutable
  .input blocked
  .decl weight(x: symbol, w: number) mutable
  .input weight

  .decl reach(x: symbol, y: symbol)
  reach(x, y) :- edge(x, y).
  reach(x, z) :- reach(x, y), edge(y, z).
  .output reach

  .decl open(x: symbol, y: symbol)
  open(x, y) :- reach(x, y), !blocked(y).
  .output open

  .decl heaviest(x: symbol, w: number)
  heaviest(x, max(w)) :- weight(x, w).
  .output heaviest

  .decl source(x: symbol)
  source(x) :- edge(x, _).
  .output source(filename="source.facts")
  """

  setup_all do
    dir = Path.join(System.tmp_dir!(), "argus_flowlog_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "graph.dl")
    File.write!(path, @program)
    {:ok, built} = FlowLog.engine(path, progress: false)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{program: path, built: built}
  end

  defp facts!(dir, relations) do
    File.mkdir_p!(dir)

    for {name, rows} <- relations do
      File.write!(Path.join(dir, "#{name}.facts"), Argus.Tsv.encode(rows))
    end

    dir
  end

  defp start!(built) do
    {:ok, engine} =
      Engine.start_link(executable: built.executable, digest: built.digest, workers: 2)

    on_exit(fn -> Engine.stop(engine) end)
    engine
  end

  defp read!(dir, file), do: dir |> Path.join(file) |> File.read!() |> FlowLog.decode_output()

  describe "the tool" do
    test "lists what a program reads and writes, after pruning", %{program: program} do
      assert {:ok, manifest} = FlowLog.manifest(program)
      assert Enum.map(manifest.inputs, & &1.name) |> Enum.sort() == ~w(blocked edge weight)

      assert %{name: "weight", file: "weight.facts", columns: ["symbol", "number"]} in manifest.inputs

      assert Enum.map(manifest.outputs, & &1.file) |> Enum.sort() ==
               ~w(heaviest.csv open.csv reach.csv source.facts)

      assert %{name: "reach", columns: [%{"name" => "x", "type" => _} | _]} =
               Enum.find(manifest.relations, &(&1.name == "reach"))
    end

    @tag :tmp_dir
    test "a program that does not compile is FlowLog's diagnostic", %{tmp_dir: tmp} do
      path = Path.join(tmp, "broken.dl")

      File.write!(
        path,
        ".decl a(x: symbol) mutable\n.input a\n.decl b(x: symbol)\nb(x) :- a(x, y).\n.output b\n"
      )

      assert {:error, {:flowlog_program, ^path, diagnostic}} = FlowLog.manifest(path)
      assert diagnostic =~ "error"
      assert diagnostic =~ "broken.dl"
    end

    @tag :tmp_dir
    test "an input not declared mutable is refused, saying why", %{tmp_dir: tmp} do
      path = Path.join(tmp, "static.dl")

      File.write!(
        path,
        ".decl a(x: symbol)\n.input a\n.decl b(x: symbol)\nb(x) :- a(x).\n.output b\n"
      )

      assert {:error, {:flowlog_program, ^path, diagnostic}} = FlowLog.manifest(path)
      assert diagnostic =~ "input relation `a` must be declared `mutable`"
    end

    @tag :tmp_dir
    test "a program that reads no input is refused", %{tmp_dir: tmp} do
      path = Path.join(tmp, "constant.dl")
      File.write!(path, ".decl out(x: symbol)\nout(\"a\").\n.output out\n")

      assert {:error, {:flowlog_program, ^path, diagnostic}} = FlowLog.manifest(path)
      assert diagnostic =~ "reads no input relation"
    end

    test "prints its manifest on stdout and nothing on stderr", %{program: program} do
      {:ok, toolchain} = FlowLog.toolchain(progress: false)

      log =
        Path.join(System.tmp_dir!(), "argus_tool_stderr_#{System.unique_integer([:positive])}")

      {_out, 0} =
        System.cmd("/bin/sh", [
          "-c",
          ~s("$0" inspect "$1" 2>"$2"),
          Argus.FlowLog.Toolchain.tool(toolchain),
          program,
          log
        ])

      assert File.read!(log) == ""
      File.rm!(log)
    end

    @tag :tmp_dir
    test "an output column argus cannot exchange is refused", %{tmp_dir: tmp} do
      path = Path.join(tmp, "tuple.dl")

      File.write!(path, """
      .type P = (a: symbol, b: symbol)
      .decl a(x: symbol) mutable
      .input a
      .decl b(p: P)
      b(p) :- a(x), p = (x, x).
      .output b
      """)

      assert {:error, {:flowlog_program, ^path, diagnostic}} = FlowLog.manifest(path)
      assert diagnostic =~ "only `symbol` and `number` columns"
    end
  end

  describe "run/3" do
    @describetag :tmp_dir

    test "solves a facts directory, every .csv output sorted", %{program: program, tmp_dir: tmp} do
      facts =
        facts!(Path.join(tmp, "facts"),
          edge: [["b", "c"], ["a", "b"]],
          blocked: [["c"]],
          weight: [["a", "3"], ["a", "7"], ["b", "1"]]
        )

      out = Path.join(tmp, "out")
      File.mkdir_p!(out)

      assert {:ok, results} = FlowLog.run(facts, program, output_dir: out)

      assert results == %{
               "reach" => [["a", "b"], ["a", "c"], ["b", "c"]],
               "open" => [["a", "b"]],
               "heaviest" => [["a", "7"], ["b", "1"]]
             }

      # A `.facts` output is a file for another program to read, not a result.
      assert read!(out, "source.facts") == [["a"], ["b"]]
    end

    test "a missing input file is an error, never an empty relation", %{
      program: program,
      tmp_dir: tmp
    } do
      facts = facts!(Path.join(tmp, "facts"), edge: [["a", "b"]], weight: [])

      assert {:error, %Argus.MissingRelationError{relation: "blocked"}} =
               FlowLog.run(facts, program)
    end

    test "empty symbol columns survive at either edge of a row", %{program: program, tmp_dir: tmp} do
      facts =
        facts!(Path.join(tmp, "facts"), edge: [["", "b"], ["b", ""]], blocked: [], weight: [])

      assert {:ok, %{"reach" => reach}} = FlowLog.run(facts, program)
      assert reach == [["", ""], ["", "b"], ["b", ""], ["b", "b"]]
    end

    test "escaped tabs and newlines travel through untouched", %{program: program, tmp_dir: tmp} do
      facts = facts!(Path.join(tmp, "facts"), edge: [["a\tb", "c\nd"]], blocked: [], weight: [])

      assert {:ok, %{"reach" => [["a\tb", "c\nd"]]}} = FlowLog.run(facts, program)
    end
  end

  describe "the query graph" do
    @describetag :tmp_dir

    test "reads a kept solve's rows back sorted", %{tmp_dir: tmp} do
      program = Path.join(tmp, "functions.dl")

      File.write!(program, """
      .include "#{Argus.Dl.path("base.dl")}"
      .decl named(name: symbol, arity: number)
      named(n, a) :- function_def(_, _, n, a, _).
      .output named
      """)

      store = Path.join(tmp, "store")
      modules = [Argus.Test.Fixtures.Quiet]
      assert {:ok, %{"named" => rows}} = Argus.analyze(modules, {:custom, program}, store: store)
      assert rows != []
      assert rows == Enum.sort(rows)
      # Again, from the store's action cache: the same rows.
      assert {:ok, %{"named" => ^rows}} = Argus.analyze(modules, {:custom, program}, store: store)
    end
  end

  describe "an engine kept between commits" do
    @describetag :tmp_dir

    test "applies only what changed, and writes only the outputs it moved",
         %{built: built, tmp_dir: tmp} do
      engine = start!(built)

      v1 =
        facts!(Path.join(tmp, "v1"),
          edge: [["a", "b"], ["b", "c"]],
          blocked: [],
          weight: [["a", "1"]]
        )

      out1 = Path.join(tmp, "out1")
      File.mkdir_p!(out1)

      inputs = Map.new(~w(edge blocked weight), &{&1, Path.join(v1, "#{&1}.facts")})
      assert {:ok, first} = Engine.commit(engine, out1, inputs, %{}, 60_000)
      assert Enum.sort(first.written) == ~w(heaviest.csv open.csv reach.csv source.facts)
      assert read!(out1, "reach.csv") == [["a", "b"], ["a", "c"], ["b", "c"]]

      # Drop b -> c: the reachability through it is retracted.
      v2 = facts!(Path.join(tmp, "v2"), edge: [["a", "b"]])
      out2 = Path.join(tmp, "out2")
      File.mkdir_p!(out2)

      assert {:ok, second} =
               Engine.commit(engine, out2, %{"edge" => Path.join(v2, "edge.facts")}, %{}, 60_000)

      assert Enum.sort(second.written) == ~w(open.csv reach.csv source.facts)
      assert second.inputs["edge"] == %{"rows" => 1, "added" => 0, "removed" => 1}
      assert read!(out2, "reach.csv") == [["a", "b"]]
      assert read!(out2, "open.csv") == [["a", "b"]]

      # Block b: only `open` moves.
      v3 = facts!(Path.join(tmp, "v3"), blocked: [["b"]])
      out3 = Path.join(tmp, "out3")
      File.mkdir_p!(out3)

      assert {:ok, third} =
               Engine.commit(
                 engine,
                 out3,
                 %{"blocked" => Path.join(v3, "blocked.facts")},
                 %{},
                 60_000
               )

      assert third.written == ["open.csv"]
      assert read!(out3, "open.csv") == []
    end

    # Recursion, negation and an aggregate, under any sequence of edits:
    # what a kept engine holds after each commit (the outputs it wrote,
    # and those it kept) is what a new engine finds from the same facts.
    property "agrees with a solve from scratch after every commit", %{built: built, tmp_dir: tmp} do
      node = member_of(~w(a b c d e))
      pair = tuple({node, node})

      step =
        fixed_map(%{
          "edge" => uniq_list_of(map(pair, &Tuple.to_list/1), max_length: 8),
          "blocked" => uniq_list_of(map(node, &[&1]), max_length: 3),
          "weight" =>
            uniq_list_of(map(tuple({node, integer(0..3)}), fn {n, w} -> [n, "#{w}"] end),
              max_length: 4
            )
        })

      check all(steps <- list_of(step, min_length: 1, max_length: 6), max_runs: 25) do
        run = Path.join(tmp, "run-#{System.unique_integer([:positive])}")
        kept = start!(built)

        Enum.reduce(Enum.with_index(steps), %{}, fn {facts, i}, held ->
          dir = facts!(Path.join(run, "facts-#{i}"), facts)
          paths = Map.new(facts, fn {name, _} -> {name, Path.join(dir, "#{name}.facts")} end)

          out = Path.join(run, "kept-#{i}")
          File.mkdir_p!(out)
          {:ok, commit} = Engine.commit(kept, out, paths, %{}, 60_000)
          held = Map.merge(held, Map.new(commit.written, &{&1, read!(out, &1)}))

          fresh = start!(built)
          scratch = Path.join(run, "fresh-#{i}")
          File.mkdir_p!(scratch)
          {:ok, solved} = Engine.commit(fresh, scratch, paths, %{}, 60_000)
          Engine.stop(fresh)

          assert held == Map.new(solved.written, &{&1, read!(scratch, &1)}),
                 "commit #{i} of #{inspect(steps)}"

          held
        end)

        Engine.stop(kept)
      end
    end

    test "a commit that changes nothing writes nothing", %{built: built, tmp_dir: tmp} do
      engine = start!(built)
      v1 = facts!(Path.join(tmp, "v1"), edge: [["a", "b"]], blocked: [], weight: [])
      inputs = Map.new(~w(edge blocked weight), &{&1, Path.join(v1, "#{&1}.facts")})
      assert {:ok, _} = Engine.commit(engine, tmp, inputs, %{}, 60_000)
      assert {:ok, %{written: []}} = Engine.commit(engine, tmp, inputs, %{}, 60_000)
      # Unless asked to write them all again (their files were lost).
      assert {:ok, %{written: written}} =
               Engine.commit(engine, tmp, %{}, %{}, 60_000, rewrite: true)

      assert length(written) == 4
    end

    test "the first commit must load every input", %{built: built, tmp_dir: tmp} do
      engine = start!(built)
      v1 = facts!(Path.join(tmp, "v1"), edge: [["a", "b"]])

      assert {:error, {:flowlog_error, "missing_inputs", message}} =
               Engine.commit(engine, tmp, %{"edge" => Path.join(v1, "edge.facts")}, %{}, 60_000)

      assert message =~ "blocked"
      assert message =~ "weight"
    end

    test "a relation the program does not read is refused", %{built: built, tmp_dir: tmp} do
      engine = start!(built)

      assert {:error, {:flowlog_error, "unknown_relation", message}} =
               Engine.commit(engine, tmp, %{"nope" => Path.join(tmp, "nope.facts")}, %{}, 60_000)

      assert message =~ "nope"
    end

    test "a malformed row fails its commit whole, and the engine goes on",
         %{built: built, tmp_dir: tmp} do
      engine = start!(built)
      v1 = facts!(Path.join(tmp, "v1"), edge: [["a", "b"]], blocked: [], weight: [["a", "2"]])
      inputs = Map.new(~w(edge blocked weight), &{&1, Path.join(v1, "#{&1}.facts")})
      assert {:ok, _} = Engine.commit(engine, tmp, inputs, %{}, 60_000)

      bad = Path.join(tmp, "bad")
      File.mkdir_p!(bad)
      File.write!(Path.join(bad, "edge.facts"), "a\tc\n")
      File.write!(Path.join(bad, "weight.facts"), "a\tmany\n")

      assert {:error, {:flowlog_error, "bad_row", message}} =
               Engine.commit(
                 engine,
                 tmp,
                 %{
                   "edge" => Path.join(bad, "edge.facts"),
                   "weight" => Path.join(bad, "weight.facts")
                 },
                 %{},
                 60_000
               )

      assert message =~ "not a 32-bit number"

      # Neither half of the failed commit was applied.
      out = Path.join(tmp, "out")
      File.mkdir_p!(out)
      assert {:ok, _} = Engine.commit(engine, out, %{}, %{}, 60_000, rewrite: true)
      assert read!(out, "reach.csv") == [["a", "b"]]
      assert read!(out, "heaviest.csv") == [["a", "2"]]
    end

    test "an engine built for another program digest is refused", %{built: built} do
      Process.flag(:trap_exit, true)

      assert {:error, {:flowlog_stale_engine, _, "another", digest}} =
               Engine.start_link(executable: built.executable, digest: "another")

      assert digest == built.digest
    end
  end

  describe "an engine's OS process" do
    @describetag :tmp_dir

    defp alive?(os_pid),
      do: match?({_, 0}, System.cmd("kill", ["-0", "#{os_pid}"], stderr_to_stdout: true))

    defp gone?(os_pid, tries \\ 50) do
      cond do
        not alive?(os_pid) -> true
        tries == 0 -> false
        true -> Process.sleep(100) && gone?(os_pid, tries - 1)
      end
    end

    test "is killed when a commit outlives its timeout", %{built: built, tmp_dir: tmp} do
      engine = start!(built)
      os_pid = Engine.os_pid(engine)
      # A long chain: its closure is millions of rows.
      chain = for i <- 1..3_000, do: ["n#{i}", "n#{i + 1}"]
      v1 = facts!(Path.join(tmp, "v1"), edge: chain, blocked: [], weight: [])
      inputs = Map.new(~w(edge blocked weight), &{&1, Path.join(v1, "#{&1}.facts")})

      assert {:error, :flowlog_timeout} = Engine.commit(engine, tmp, inputs, %{}, 50)
      assert gone?(os_pid)
    end

    test "ends when the process owning it dies", %{built: built} do
      parent = self()

      owner =
        spawn(fn ->
          {:ok, engine} = Engine.start_link(executable: built.executable, digest: built.digest)
          send(parent, {:os_pid, Engine.os_pid(engine)})
          Process.sleep(:infinity)
        end)

      assert_receive {:os_pid, os_pid}, 30_000
      assert alive?(os_pid)
      Process.exit(owner, :kill)
      assert gone?(os_pid)
    end
  end
end
