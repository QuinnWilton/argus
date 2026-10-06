defmodule Argus.SouffleTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle

  @moduletag :tmp_dir

  describe "available?/0" do
    test "returns a boolean" do
      assert is_boolean(Souffle.available?())
    end
  end

  describe "input_relations/2" do
    @describetag :souffle

    test "returns compiler diagnostics for a mismatched declaration", %{tmp_dir: tmp_dir} do
      rules_path = Path.join(tmp_dir, "bad_arity.dl")

      File.write!(rules_path, """
      .decl catch_class(id: symbol, func: symbol, class: symbol, span_end: symbol, extra: number)
      .input catch_class
      .decl try_takes(id: symbol, class: symbol)
      .output try_takes
      try_takes(id, class) :- catch_class(id, _, class, _).
      """)

      assert {:error, {:souffle_error, status, diagnostics}} = Souffle.input_relations(rules_path)
      assert status != 0
      assert diagnostics =~ "Mismatching arity of relation catch_class (expected 5, got 4)"

      assert {:error, {:souffle_error, ^status, diagnostics}} =
               Souffle.ram_io(Souffle.executable(), rules_path)

      assert diagnostics =~ "Mismatching arity of relation catch_class (expected 5, got 4)"
    end

    test "a shipped program resolves to the same inputs on every call" do
      path = Argus.Analysis.stage0_rules_path()

      assert {:ok, [_ | _] = first} = Souffle.input_relations(path)
      assert {:ok, ^first} = Souffle.input_relations(path)
    end

    @tag :tmp_dir
    test "a program outside priv/dl is read afresh on every call", %{tmp_dir: tmp_dir} do
      rules_path = Path.join(tmp_dir, "grows.dl")

      File.write!(rules_path, """
      .decl edge(x: symbol, y: symbol)
      .input edge
      .decl path(x: symbol, y: symbol)
      .output path
      path(x, y) :- edge(x, y).
      """)

      assert {:ok, ["edge"]} = Souffle.input_relations(rules_path)

      File.write!(rules_path, """
      .decl edge(x: symbol, y: symbol)
      .input edge
      .decl blocked(x: symbol)
      .input blocked
      .decl path(x: symbol, y: symbol)
      .output path
      path(x, y) :- edge(x, y), !blocked(x).
      """)

      assert {:ok, ["blocked", "edge"]} = Souffle.input_relations(rules_path)
    end
  end

  describe "run/3" do
    @describetag :souffle

    @tag :tmp_dir
    test "runs a trivial Datalog program", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")
      output_dir = Path.join(tmp_dir, "output")
      rules_path = Path.join(tmp_dir, "test.dl")

      File.mkdir_p!(facts_dir)
      File.mkdir_p!(output_dir)

      # Write a simple edge relation.
      File.write!(Path.join(facts_dir, "edge.facts"), "a\tb\nb\tc\nc\td\n")

      # Write Datalog rules.
      File.write!(rules_path, """
      .decl edge(x: symbol, y: symbol)
      .input edge

      .decl path(x: symbol, y: symbol)
      .output path

      path(x, y) :- edge(x, y).
      path(x, z) :- path(x, y), edge(y, z).
      """)

      assert {:ok, results} = Souffle.run(facts_dir, rules_path, output_dir: output_dir)
      assert Map.has_key?(results, "path")

      paths = results["path"]
      # a->b, a->c, a->d, b->c, b->d, c->d = 6 paths.
      assert length(paths) == 6

      # Check a specific path exists.
      assert ["a", "d"] in paths
    end

    @tag :tmp_dir
    test "returns error for invalid rules", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")
      rules_path = Path.join(tmp_dir, "bad.dl")

      File.mkdir_p!(facts_dir)
      File.write!(rules_path, "this is not valid datalog!!!")

      assert {:error, {:souffle_error, _, _}} = Souffle.run(facts_dir, rules_path)
    end

    @tag souffle: false
    @tag :tmp_dir
    test "returns souffle_not_found when binary missing", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")
      rules_path = Path.join(tmp_dir, "rules.dl")

      File.mkdir_p!(facts_dir)
      File.write!(rules_path, "")

      assert {:error, :souffle_not_found} =
               Souffle.run(facts_dir, rules_path, souffle_bin: nil)
    end

    @tag :tmp_dir
    test "returns souffle_error when output_dir does not exist", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")
      rules_path = Path.join(tmp_dir, "rules.dl")

      File.mkdir_p!(facts_dir)

      File.write!(rules_path, """
      .decl dummy(x: symbol)
      .output dummy
      """)

      # Passing a nonexistent output_dir — Souffle will fail because
      # the directory doesn't exist. The mkdir_failed path in
      # resolve_output_dir only triggers for auto-generated temp dirs
      # (no explicit output_dir), which requires mocking System.tmp_dir.
      assert {:error, {:souffle_error, _, _}} =
               Souffle.run(facts_dir, rules_path, output_dir: "/dev/null/impossible")
    end

    @tag :tmp_dir
    test "returns souffle_timeout when execution exceeds limit", %{tmp_dir: tmp_dir} do
      facts_dir = Path.join(tmp_dir, "facts")
      output_dir = Path.join(tmp_dir, "output")
      rules_path = Path.join(tmp_dir, "slow.dl")

      File.mkdir_p!(facts_dir)
      File.mkdir_p!(output_dir)

      # Generate a large fact file to keep Souffle busy.
      rows = Enum.map_join(1..1000, "\n", fn i -> "n#{i}\tn#{i + 1}" end)
      File.write!(Path.join(facts_dir, "edge.facts"), rows)

      # Transitive closure over 1000 nodes — heavy enough to exceed 1ms.
      File.write!(rules_path, """
      .decl edge(x: symbol, y: symbol)
      .input edge

      .decl path(x: symbol, y: symbol)
      .output path

      path(x, y) :- edge(x, y).
      path(x, z) :- path(x, y), edge(y, z).
      """)

      # 1ms timeout should be too short for transitive closure.
      assert {:error, :souffle_timeout} =
               Souffle.run(facts_dir, rules_path, output_dir: output_dir, souffle_timeout: 1)
    end
  end

  # The solver is a stand-in that sleeps, named by `:souffle_bin` rather
  # than put on PATH, so these tests touch no VM-wide state.
  describe "a solve that does not finish" do
    test "is killed at the deadline, not left running", %{tmp_dir: tmp_dir} do
      {bin, pid_file} = sleeping_solver(tmp_dir)

      # Long enough for the stand-in to start and write its pid on a
      # loaded machine (a shell's start-up alone has taken 300 ms).
      assert {:error, :souffle_timeout} =
               Souffle.run(tmp_dir, Path.join(tmp_dir, "rules.dl"),
                 souffle_bin: bin,
                 souffle_timeout: 2_000,
                 output_dir: tmp_dir
               )

      os_pid = await_pid(pid_file)
      assert gone?(os_pid), "the timed-out solver (pid #{os_pid}) is still running"
    end

    test "is killed when its caller dies first", %{tmp_dir: tmp_dir} do
      {bin, pid_file} = sleeping_solver(tmp_dir)

      caller =
        spawn(fn ->
          Souffle.run(tmp_dir, Path.join(tmp_dir, "rules.dl"),
            souffle_bin: bin,
            souffle_timeout: 60_000,
            output_dir: tmp_dir
          )
        end)

      os_pid = await_pid(pid_file)
      Process.exit(caller, :kill)

      assert gone?(os_pid), "the orphaned solver (pid #{os_pid}) is still running"
    end

    # An interrupted `mix compile` halts the VM with the solver running;
    # nothing in the VM gets to run cleanup, so the solver must stop on
    # its own when the VM's end of the port goes.
    test "stops when the VM halts under it", %{tmp_dir: tmp_dir} do
      {bin, pid_file} = sleeping_solver(tmp_dir)
      ebin = Argus.Souffle |> :code.which() |> Path.dirname()

      script = """
      spawn(fn ->
        Argus.Souffle.run(#{inspect(tmp_dir)}, #{inspect(Path.join(tmp_dir, "rules.dl"))},
          souffle_bin: #{inspect(bin)}, souffle_timeout: 60_000, output_dir: #{inspect(tmp_dir)})
      end)

      started? = fn started? ->
        File.exists?(#{inspect(pid_file)}) or (Process.sleep(10) == :ok and started?.(started?))
      end

      started?.(started?)
      :erlang.halt(0)
      """

      elixir = System.find_executable("elixir") || flunk("elixir is not on PATH")
      {_, 0} = System.cmd(elixir, ["-pa", ebin, "-e", script])

      os_pid = await_pid(pid_file)
      assert gone?(os_pid), "the solver (pid #{os_pid}) outlived the VM that started it"
    end
  end

  defp sleeping_solver(tmp_dir) do
    pid_file = Path.join(tmp_dir, "solver.pid")
    bin = Path.join(tmp_dir, "souffle")

    File.write!(bin, """
    #!/bin/sh
    echo $$ > '#{pid_file}'
    exec sleep 30
    """)

    File.chmod!(bin, 0o755)
    {bin, pid_file}
  end

  defp await_pid(pid_file, tries \\ 200) do
    case File.read(pid_file) do
      {:ok, content} when content != "" ->
        String.trim(content)

      _ when tries > 0 ->
        Process.sleep(10)
        await_pid(pid_file, tries - 1)

      _ ->
        flunk("the solver never started")
    end
  end

  # `kill -0` succeeds while the process exists; the kill is asynchronous,
  # so give it a moment.
  defp gone?(os_pid, tries \\ 200) do
    {_, status} = System.cmd("/bin/sh", ["-c", ~s(kill -0 "$1" 2>/dev/null), "sh", os_pid])
    alive? = status == 0

    cond do
      not alive? ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(10)
        gone?(os_pid, tries - 1)
    end
  end
end
