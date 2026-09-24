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

  defp kept(cache), do: cache |> File.ls!() |> Enum.sort()

  describe "a solve cache" do
    test "reads a kept solve back: the directory stands for the facts, which are not read",
         %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert [<<"p-", key::binary-size(64)>>] = kept(cache)
      assert key =~ ~r/^[0-9a-f]+$/

      File.write!(Path.join(facts, "edge.facts"), "c\td\n")
      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)
    end

    test "an edit to an included file is a new solve", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, %{"path" => [["a", "b"]]}} = Souffle.run(facts, rules, solve_cache: cache)

      File.write!(Path.join(tmp, "lib/path.dl"), "path(y, x) :- edge(x, y).\n")
      # The stamps are trusted for a second (`Cache.stamped/2`).
      Process.sleep(1_100)

      assert {:ok, %{"path" => [["b", "a"]]}} = Souffle.run(facts, rules, solve_cache: cache)
      assert length(kept(cache)) == 2
    end

    test "a salt is part of the key", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      assert {:ok, _} = Souffle.run(facts, rules, solve_cache: {cache, ["one"]})
      assert {:ok, _} = Souffle.run(facts, rules, solve_cache: {cache, ["two"]})
      assert length(kept(cache)) == 2
    end

    test "copies the outputs into a caller's output directory, hit or miss", %{tmp_dir: tmp} do
      skip_without_souffle()
      {rules, facts} = program!(tmp)
      cache = Path.join(tmp, "solves")

      for out <- [Path.join(tmp, "out1"), Path.join(tmp, "out2")] do
        assert {:ok, _} = Souffle.run(facts, rules, solve_cache: cache, output_dir: out)
        target = Path.join(out, "path.csv")
        assert File.read!(target) == "a\tb\n"

        # A copy: writing it leaves the kept solve alone.
        assert File.stat!(target).links == 1
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
