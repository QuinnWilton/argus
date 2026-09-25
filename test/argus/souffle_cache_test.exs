defmodule Argus.Souffle.CacheTest do
  use ExUnit.Case, async: true

  alias Argus.Souffle
  alias Argus.Souffle.Cache

  @moduletag :tmp_dir

  defp skip_without_souffle do
    unless Souffle.available?(), do: flunk("souffle not installed")
  end

  # A program over `edge` that includes its output's rule from a second
  # file, as the shipped programs include their clientlib.
  defp program!(dir) do
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "lib/path.dl"), """
    path(x, y) :- edge(x, y).
    """)

    File.write!(Path.join(dir, "p.dl"), """
    .decl edge(x: symbol, y: symbol)
    .input edge
    .decl path(x: symbol, y: symbol)
    .output path
    .include "lib/path.dl"
    """)

    facts = Path.join(dir, "facts")
    File.mkdir_p!(facts)
    File.write!(Path.join(facts, "edge.facts"), "a\tb\n")
    {Path.join(dir, "p.dl"), facts}
  end

  defp kept(cache) do
    case File.ls(cache) do
      {:ok, names} -> Enum.sort(names)
      {:error, :enoent} -> []
    end
  end

  describe "a solve cache" do
    # They test the store, which ARGUS_NO_CACHE turns off.
    @describetag :cache

    test "reads a kept solve back while the files it reads are unchanged",
         %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert [<<"p-", key::binary-size(64)>>] = kept(cache)
      assert key =~ ~r/^[0-9a-f]+$/

      # A file the program does not read is not part of the key.
      File.write!(Path.join(facts, "unread.facts"), "x\n")
      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert length(kept(cache)) == 1

      # One it reads is: new content, a new solve.
      File.write!(Path.join(facts, "edge.facts"), "c\td\n")
      assert {:ok, %{"path" => [["c", "d"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert length(kept(cache)) == 2

      # And the old content finds the old solve again.
      File.write!(Path.join(facts, "edge.facts"), "a\tb\n")
      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert length(kept(cache)) == 2
    end

    test "an edit to an included file is a new solve", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)

      # A program outside priv/dl is read on every call.
      File.write!(Path.join(tmp, "lib/path.dl"), "path(y, x) :- edge(x, y).\n")

      assert {:ok, %{"path" => [["b", "a"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert length(kept(cache)) == 2
    end

    test "a group is part of the entry's name, for retention", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, _} = Souffle.run(facts, rules, solve_cache: {cache, "one"})
      assert [<<"p-one-", _key::binary-size(64)>>] = kept(cache)
    end

    test "a kept solve's files are read-only, beside a manifest of their digests",
         %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, _} = Souffle.run(facts, rules, solve_cache: cache)
      [name] = kept(cache)
      entry = Path.join(cache, name)

      assert File.stat!(Path.join(entry, "path.csv")).access == :read
      assert {:ok, %{"path.csv" => digest}} = Cache.manifest(entry)
      assert {:ok, ^digest} = Argus.Cache.file_digest(Path.join(entry, "path.csv"))
    end

    test "copies the outputs into a caller's output directory, hit or miss", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      for out <- [Path.join(tmp, "out1"), Path.join(tmp, "out2")] do
        assert {:ok, _} = Souffle.run(facts, rules, solve_cache: cache, output_dir: out)
        target = Path.join(out, "path.csv")
        assert File.read!(target) == "a\tb\n"

        # A copy, the caller's to write: writing it leaves the kept solve
        # alone.
        assert File.stat!(target).links == 1
        assert File.stat!(target).access == :read_write
        refute File.exists?(Path.join(out, ".argus-digests"))
      end
    end

    test "a failed solve is reported every time and never kept", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      File.write!(rules, "not datalog\n")
      cache = Path.join(tmp, "solves")

      assert {:error, {:souffle_error, _, _}} = Souffle.run(facts, rules, solve_cache: cache)
      assert {:error, {:souffle_error, _, _}} = Souffle.run(facts, rules, solve_cache: cache)
      assert kept(cache) == []
    end
  end

  describe "input files" do
    test "are the files the program reads, named by a filename it gives",
         %{tmp_dir: tmp} do
      skip_without_souffle()
      rules = Path.join(tmp, "q.dl")

      File.write!(rules, """
      .decl a(x: symbol)
      .input a
      .decl b(x: symbol)
      .input b(filename="other.facts")
      .decl unused(x: symbol)
      .input unused
      .decl out(x: symbol)
      .output out
      out(x) :- a(x), b(x).
      """)

      assert {:ok, ["a.facts", "other.facts"]} = Souffle.input_files(rules)
      assert {:ok, ["a", "b"]} = Souffle.input_relations(rules)
    end

    test "are kept in a store's programs directory for the next VM", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, _facts} = program!(tmp)
      programs = Path.join(tmp, "programs")

      assert {:ok, ["edge"]} = Souffle.input_relations(rules, programs: programs)

      # Beside the solver's version, when its binary can be stamped
      # (`version/2`).
      assert [<<"p-", _key::binary-size(64)>> = name] =
               programs |> File.ls!() |> Enum.reject(&String.starts_with?(&1, "souffle-"))

      assert File.read!(Path.join(programs, name)) == "edge\tedge.facts\n"
    end
  end

  describe "version/2" do
    # A solver on disk that is not a script: a link to a system binary,
    # which answers `--version` as it answers anything (`echo` prints
    # the argument back, `true` prints nothing, `false` fails).
    defp solver!(tmp, target) do
      bin = Path.join(tmp, "souffle")
      File.rm(bin)
      File.ln_s!(target, bin)
      bin
    end

    defp kept_versions(dir) do
      case File.ls(dir) do
        {:ok, names} -> names |> Enum.filter(&String.starts_with?(&1, "souffle-")) |> Enum.sort()
        {:error, :enoent} -> []
      end
    end

    # The version a fresh VM — one that has asked no solver — gives.
    defp fresh_version(bin, dir) do
      {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io})

      try do
        :ok = :peer.call(peer, :code, :add_pathsa, [:code.get_path()])
        :peer.call(peer, Cache, :version, [bin, dir], 60_000)
      after
        :peer.stop(peer)
      end
    end

    test "keeps the answer under the binary's stamp for the next VM", %{tmp_dir: tmp} do
      bin = solver!(tmp, "/bin/echo")
      dir = Path.join(tmp, "programs")
      {answer, 0} = System.cmd(bin, ["--version"])

      assert Cache.version(bin, dir) == answer
      assert [<<"souffle-", _key::binary-size(64)>> = kept] = kept_versions(dir)
      assert File.read!(Path.join(dir, kept)) == answer

      # A fresh VM reads the kept answer instead of asking: a planted
      # one shows.
      File.chmod!(Path.join(dir, kept), 0o644)
      File.write!(Path.join(dir, kept), "planted")
      assert fresh_version(bin, dir) == "planted"

      # Another binary at the same path is another stamp: asked again.
      bin = solver!(tmp, "/usr/bin/true")
      assert fresh_version(bin, dir) == ""
      assert length(kept_versions(dir)) == 2
    end

    test "asks a script every time and keeps nothing", %{tmp_dir: tmp} do
      # A version manager's shim runs another solver without moving.
      bin = Path.join(tmp, "souffle")
      File.write!(bin, "#!/bin/sh\necho 2.5\n")
      File.chmod!(bin, 0o755)
      File.touch!(bin, System.os_time(:second) - 60)
      dir = Path.join(tmp, "programs")

      assert Cache.version(bin, dir) == "2.5\n"
      assert kept_versions(dir) == []
    end

    test "keeps nothing a solver answered by failing", %{tmp_dir: tmp} do
      bin = solver!(tmp, "/usr/bin/false")
      dir = Path.join(tmp, "programs")

      assert Cache.version(bin, dir) == ""
      assert kept_versions(dir) == []
    end

    test "without a store is version/1", %{tmp_dir: tmp} do
      bin = solver!(tmp, "/bin/echo")
      assert Cache.version(bin, nil) == Cache.version(bin)
    end
  end

  describe "program_digest/1" do
    test "is the program and its includes, wherever the tree is", %{tmp_dir: tmp} do
      {one, _} = program!(Path.join(tmp, "one"))
      {two, _} = program!(Path.join(tmp, "two"))

      assert Cache.program_digest(one) == Cache.program_digest(two)

      assert Cache.program_files(one) == [
               {"p.dl", one},
               {"lib/path.dl", Path.join([tmp, "one", "lib", "path.dl"])}
             ]
    end
  end

  describe "named/6" do
    test "keys a program by the declarations it loads; named/5 resolves them", %{tmp_dir: tmp} do
      skip_without_souffle()

      File.write!(Path.join(tmp, "decls.dl"), """
      // Declarations alone, as mix argus.gen.dl writes them.
      .decl edge(x: symbol, y: symbol)
      .input edge
      .decl unread(x: symbol)
      .input unread
      """)

      rules = Path.join(tmp, "p.dl")

      File.write!(rules, """
      .include "decls.dl"
      .decl path(x: symbol, y: symbol)
      .output path
      path(x, y) :- edge(x, y).
      """)

      bin = Souffle.executable()
      digests = [{"edge.facts", "d"}]
      assert {:ok, ["edge"]} = Souffle.input_relations(rules)

      entry = Cache.named(tmp, nil, rules, bin, digests, ["edge"])
      refute entry == Cache.named(tmp, nil, rules, bin, digests, :all)

      # Deprecated: called through apply so the suite compiles clean.
      assert apply(Cache, :named, [tmp, nil, rules, bin, digests]) == entry

      # A declaration the program does not load moves nothing.
      File.write!(
        Path.join(tmp, "decls.dl"),
        File.read!(Path.join(tmp, "decls.dl")) <> ".decl added(y: number)\n.input added\n"
      )

      assert Cache.named(tmp, nil, rules, bin, digests, ["edge"]) == entry
    end
  end

  describe "stamped/2" do
    test "computes again once a file it read has moved, if only in content",
         %{tmp_dir: tmp} do
      file = Path.join(tmp, "input")
      File.write!(file, "one")
      key = {__MODULE__, make_ref()}
      compute = fn -> {[file], File.read!(file)} end

      assert Cache.stamped(key, compute) == "one"
      File.write!(file, "two")
      # Within the second the value is trusted without a stat.
      assert Cache.stamped(key, compute) == "one"

      Process.sleep(1_100)
      assert Cache.stamped(key, compute) == "two"
    end
  end
end
