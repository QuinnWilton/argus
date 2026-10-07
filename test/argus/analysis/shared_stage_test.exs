defmodule Argus.Analysis.SharedStageTest do
  @moduledoc """
  A stage derived into a facts directory that another derivation of the
  same stage shares answers as it would alone. scry names its fact
  directories by their content, so every solve over the same facts
  (async tests over one fixture, an LSP session beside a compile)
  derives stage 0 and the points-to stage into the same directory at
  once. `Argus.Analysis.Extraction.derive_stage0/2` and
  `derive_points_to/2` solve into a directory of their own and rename
  each output into place.

  Each engine here is the real one behind a proxy that holds a
  derivation where its race needs it (`Argus.Test.FailingEngine.proxy/3`),
  so each interleaving happens on every run. Not async: the proxies
  live in a cache root named by a VM-wide variable.
  """

  use ExUnit.Case, async: false
  @moduletag :flowlog

  alias Argus.Analysis
  alias Argus.Test.FailingEngine
  alias Argus.Test.Files
  alias Argus.Test.Fixtures.PidFlow

  @moduletag :tmp_dir

  # Servers each caller reaches through a helper, both stages derived:
  # each has rows to stage.
  defp facts! do
    modules =
      for name <- ~w(SafeCall UserA UserB TargetA TargetB), do: Module.concat(PidFlow, name)

    {:ok, dir} = Analysis.extract_facts(modules, [:startup])
    on_exit(fn -> Files.rm_rf!(Path.dirname(dir)) end)
    assert File.read!(Path.join(dir, "process_call.facts")) != ""
    dir
  end

  # Runs `fun` with the engines of `programs` behind a proxy that runs
  # `before` ahead of every commit and `after_commit` once it is done,
  # `$out` the commit's output directory.
  defp proxied(programs, before, after_commit, fun) do
    FailingEngine.with(programs, fun, stub: &FailingEngine.proxy(&1, before, after_commit))
  end

  # Until `mark` names a file in `marks`, on the engine's side.
  defp wait_sh(marks, mark), do: ~s(while [ ! -e "#{marks}/#{mark}" ]; do sleep 0.01; done)

  # Until `mark` names a file in `marks`, on this side.
  defp await_mark!(marks, mark, tries \\ 3_000) do
    cond do
      File.exists?(Path.join(marks, mark)) ->
        :ok

      tries == 0 ->
        flunk("the engine never reached #{mark}")

      true ->
        Process.sleep(10)
        await_mark!(marks, mark, tries - 1)
    end
  end

  defp marks!(tmp) do
    marks = Path.join(tmp, "marks")
    File.mkdir_p!(marks)
    # Whatever the test's outcome, no engine is left waiting.
    on_exit(fn -> File.write(Path.join(marks, "go"), "") end)
    marks
  end

  defp staged(dir, relations) do
    Map.new(relations, &{&1, File.read!(Path.join(dir, &1 <> ".facts"))})
  end

  @tag :capture_log
  test "two derivations of the points-to stage into one directory each read their own report",
       %{tmp_dir: tmp} do
    dir = facts!()
    marks = marks!(tmp)

    # The first commit to finish holds, its outputs written, until told
    # to go on: the other derivation runs whole in between, reading its
    # report and taking it away. `mkdir` is the test-and-set.
    hold = """
    if mkdir "#{marks}/held" 2>/dev/null; then
      touch "#{marks}/holding"
      #{wait_sh(marks, "go")}
    fi
    """

    proxied(["points_to.dl", "points_to_bounded.dl"], "", hold, fn ->
      first = Task.async(fn -> Analysis.derive_points_to(dir) end)
      await_mark!(marks, "holding")

      assert :ok = Analysis.derive_points_to(dir)
      File.write!(Path.join(marks, "go"), "")
      assert :ok = Task.await(first, 60_000)
    end)

    assert File.read!(Path.join(dir, "points_to_mode.facts")) == "exact\n"
    # Neither report is left among the facts.
    refute File.exists?(Path.join(dir, "points_to_overflow.csv"))
    refute File.exists?(Path.join(dir, "pervasive.csv"))
    assert dir |> File.ls!() |> Enum.filter(&String.starts_with?(&1, ".")) == []
  end

  for {stage, derive, relations} <- [
        {"stage 0", :derive_stage0, :stage0_relations},
        {"the points-to stage", :derive_points_to, :points_to_relations}
      ] do
    @tag :capture_log
    test "#{stage} derived again leaves a reader of the directory every staged file whole",
         %{tmp_dir: tmp} do
      dir = facts!()
      marks = marks!(tmp)
      relations = apply(Analysis, unquote(relations), [])
      derive = fn opts -> apply(Analysis, unquote(derive), [dir, opts]) end
      before = staged(dir, relations)

      # An engine opens each of its outputs truncated before it writes
      # it: this one's proxy opens them all, then holds before it solves.
      truncates = Enum.map_join(relations, "\n", &~s(: > "$out/#{&1}.facts"))

      programs =
        if unquote(derive) == :derive_stage0,
          do: ["stage0.dl"],
          else: ["points_to.dl", "points_to_bounded.dl"]

      proxied(
        programs,
        truncates <> "\ntouch \"#{marks}/opened\"\n" <> wait_sh(marks, "go"),
        "",
        fn ->
          again = Task.async(fn -> derive.([]) end)
          await_mark!(marks, "opened")

          assert staged(dir, relations) == before
          File.write!(Path.join(marks, "go"), "")
          assert :ok = Task.await(again, 60_000)
        end
      )

      assert staged(dir, relations) == before
    end
  end
end
