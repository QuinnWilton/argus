defmodule Argus.FlowLog.BuilderTest do
  @moduledoc """
  Engines asked for while a build runs are built together after it, in
  one Cargo build, whoever asked (`Argus.FlowLog.Builder`); a program
  that fails fails only the callers that asked for it.

  The test runs in a peer (`Argus.Test.Peer`): `ARGUS_CARGO` (a wrapper
  that records each build before running the real Cargo) and the cache
  root are VM-wide. The cache root links to the suite's toolchain but
  for its `engines/`, so the programs, new each run, build and install
  apart from the suite's.
  """
  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.FlowLog
  alias Argus.FlowLog.Program
  alias Argus.FlowLog.Toolchain
  alias Argus.Test.Peer

  @moduletag :flowlog
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {:ok, toolchain} = FlowLog.toolchain(progress: false)
    {:ok, rust} = Toolchain.rust()

    root = Path.join(tmp, "cache")
    dir = Path.join(root, Path.basename(toolchain.dir))
    File.mkdir_p!(Path.join(dir, "engines"))
    File.chmod!(root, 0o700)

    for entry <- ~w(bin sources target logs crates),
        do: File.ln_s!(Path.join(toolchain.dir, entry), Path.join(dir, entry))

    log = Path.join(tmp, "cargo.log")
    cargo = Path.join(tmp, "cargo")

    File.write!(cargo, """
    #!/bin/sh
    if [ "$1" = "build" ]; then echo "$*" >> "#{log}"; fi
    exec "#{rust.cargo}" "$@"
    """)

    File.chmod!(cargo, 0o755)
    %{peer: Peer.start!(), root: root, cargo: cargo, log: log}
  end

  # A program no run has built before.
  defp program!(tmp, name) do
    relation = "#{name}_#{System.unique_integer([:positive])}"
    path = Path.join(tmp, "#{name}.dl")

    File.write!(path, """
    .decl edge(a: symbol, b: symbol) mutable
    .input edge
    .decl #{relation}(a: symbol)
    .output #{relation}
    #{relation}(a) :- edge(a, _).
    """)

    path
  end

  defp builds(log) do
    case File.read(log) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp eventually(fun, tries \\ 600) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  test "programs asked for during a build share the next one, and a failure is its asker's",
       %{peer: peer, root: root, cargo: cargo, log: log, tmp_dir: tmp} do
    [first, second, third] = for name <- ~w(first second third), do: program!(tmp, name)
    missing = Path.join(tmp, "missing.dl")

    Peer.run(peer, fn ->
      System.put_env("ARGUS_FLOWLOG_DIR", root)
      System.put_env("ARGUS_CARGO", cargo)
      System.put_env("ARGUS_FLOWLOG_BUILD_PROFILE", "quick")
      {:ok, toolchain} = FlowLog.toolchain(progress: false)

      running = Task.async(fn -> FlowLog.engine(first, progress: false) end)
      assert eventually(fn -> length(builds(log)) == 1 end)

      waiting =
        for path <- [second, third],
            do: Task.async(fn -> FlowLog.engine(path, progress: false) end)

      # A program the tool cannot generate, asked for by a caller of its
      # own: it fails that caller, and the batch it shares builds the rest.
      failing =
        Task.async(fn -> Program.engines(toolchain, [{missing, "0" |> String.duplicate(64)}]) end)

      assert {:ok, %{executable: built}} = Task.await(running, :infinity)
      assert String.ends_with?(built, "/engine-quick")

      for task <- waiting, do: assert({:ok, _} = Task.await(task, :infinity))
      assert {:error, {:flowlog_program, ^missing, _}} = Task.await(failing, :infinity)

      assert [_first_build, shared] = builds(log)
      assert length(Regex.scan(~r/--bin engine-/, shared)) == 2
      assert shared =~ "--profile quick"
    end)
  end
end
