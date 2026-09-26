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

  Each solver here is the real one behind a script that holds a
  derivation where its race needs it, so each interleaving happens on
  every run.
  """

  use ExUnit.Case, async: true

  alias Argus.Analysis
  alias Argus.Souffle
  alias Argus.Test.Fixtures.PidFlow

  @moduletag :tmp_dir

  setup do
    unless Souffle.available?(), do: flunk("souffle not installed")
    :ok
  end

  # Servers each caller reaches through a helper, both stages derived:
  # each has rows to stage.
  defp facts! do
    modules =
      for name <- ~w(SafeCall UserA UserB TargetA TargetB), do: Module.concat(PidFlow, name)

    {:ok, dir} = Analysis.extract_facts(modules, [:startup])
    on_exit(fn -> File.rm_rf!(Path.dirname(dir)) end)
    assert File.read!(Path.join(dir, "process_call.facts")) != ""
    dir
  end

  # The real solver, run by a script: a solve (`-F` among its arguments,
  # not a question such as `--version`) first runs `before`, then the
  # solver, then `after_solve`; `$out` is its output directory. Each
  # script names the marks it leaves and waits for in `marks`.
  defp solver!(tmp, name, before, after_solve) do
    bin = Path.join(tmp, name)

    File.write!(bin, """
    #!/bin/sh
    case " $* " in
      *" -F "*) ;;
      *) exec #{System.find_executable("souffle")} "$@" ;;
    esac
    out=""
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-D" ]; then out="$arg"; fi
      prev="$arg"
    done
    #{before}
    #{System.find_executable("souffle")} "$@" || exit $?
    #{after_solve}
    """)

    File.chmod!(bin, 0o755)
    bin
  end

  # Until `mark` names a file in `marks`, on the solver's side.
  defp wait_sh(marks, mark), do: ~s(while [ ! -e "#{marks}/#{mark}" ]; do sleep 0.01; done)

  # Until `mark` names a file in `marks`, on this side.
  defp await_mark!(marks, mark, tries \\ 3_000) do
    cond do
      File.exists?(Path.join(marks, mark)) ->
        :ok

      tries == 0 ->
        flunk("the solver never reached #{mark}")

      true ->
        Process.sleep(10)
        await_mark!(marks, mark, tries - 1)
    end
  end

  defp marks!(tmp) do
    marks = Path.join(tmp, "marks")
    File.mkdir_p!(marks)
    # Whatever the test's outcome, no solver is left waiting.
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

    # The first solver to finish holds, its outputs written, until told
    # to exit: the other derivation runs whole in between, reading its
    # report and taking it away. `mkdir` is the test-and-set.
    bin =
      solver!(tmp, "souffle-holding", "", """
      if mkdir "#{marks}/held" 2>/dev/null; then
        touch "#{marks}/holding"
        #{wait_sh(marks, "go")}
      fi
      """)

    first = Task.async(fn -> Analysis.derive_points_to(dir, souffle_bin: bin) end)
    await_mark!(marks, "holding")

    assert :ok = Analysis.derive_points_to(dir, souffle_bin: bin)
    File.write!(Path.join(marks, "go"), "")
    assert :ok = Task.await(first, 60_000)

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

      # A solver opens each of its outputs truncated before it writes
      # it: this one opens them all, then holds before it solves.
      truncates = Enum.map_join(relations, "\n", &~s(: > "$out/#{&1}.facts"))

      bin =
        solver!(
          tmp,
          "souffle-opening",
          truncates <> "\ntouch \"#{marks}/opened\"\n" <> wait_sh(marks, "go"),
          ""
        )

      again = Task.async(fn -> derive.(souffle_bin: bin) end)
      await_mark!(marks, "opened")

      assert staged(dir, relations) == before
      File.write!(Path.join(marks, "go"), "")
      assert :ok = Task.await(again, 60_000)
      assert staged(dir, relations) == before
    end
  end
end
