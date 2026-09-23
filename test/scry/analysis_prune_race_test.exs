defmodule Scry.AnalysisPruneRaceTest do
  @moduledoc """
  The scratch root is shared across VMs (planchette's LSP, compiler
  runs), and another process can prune a fact directory while Souffle
  is reading it. The solve rebuilds it and runs again instead of
  reporting the analysis degraded.
  """

  # PATH manipulation — never async.
  use ExUnit.Case, async: false

  alias Scry.Test.Graph

  @moduletag :souffle
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # A souffle that, the first time it is asked to run a program, deletes
  # the fact directory it was handed and fails — a prune lost mid-solve.
  defp racing_souffle!(dir) do
    real = System.find_executable("souffle")
    marker = Path.join(dir, "race_once")
    File.write!(marker, "")
    wrapper = Path.join(dir, "souffle")

    File.write!(wrapper, """
    #!/bin/sh
    case "$1" in --show*|--version) exec #{real} "$@";; esac
    if [ -e #{marker} ]; then
      rm -f #{marker}
      prev=""
      for arg in "$@"; do
        if [ "$prev" = "-F" ]; then rm -rf "$arg"; fi
        prev="$arg"
      done
      echo "cannot open fact file" >&2
      exit 1
    fi
    exec #{real} "$@"
    """)

    File.chmod!(wrapper, 0o755)
    marker
  end

  test "a directory pruned during the solve is rebuilt and solved", %{tmp_dir: dir} do
    paths = Graph.compile_parity!(Path.join(System.tmp_dir!(), "scry_race_ebin"))
    db = Graph.new_db(paths)
    # Everything up to the solve, with the real solver.
    %{dir: facts} = Scry.Analysis.analysis_facts_dir(db, :mailbox)

    marker = racing_souffle!(dir)
    original = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> original)

    try do
      assert {:ok, _outputs} = Scry.Analysis.souffle_solve(db, :mailbox)
      # The race happened, and the rebuilt directory is where it was.
      refute File.exists?(marker)
      assert File.dir?(facts)
    after
      System.put_env("PATH", original)
    end
  end

  test "a relation store entry that is not the file is replaced", %{tmp_dir: _dir} do
    paths = Graph.compile_parity!(Path.join(System.tmp_dir!(), "scry_race_ebin"))
    db = Graph.new_db(paths)
    %{dir: facts} = Scry.Analysis.analysis_facts_dir(db, :mailbox)

    # The directory goes (pruned), and one of the files it linked is
    # replaced in the store by something that cannot be linked or copied.
    [linked | _] = facts |> File.ls!() |> Enum.sort()
    relation = Path.basename(linked, ".facts")
    digest = Scry.Analysis.relation_digest(db, String.to_existing_atom(relation))

    store =
      Path.join([System.tmp_dir!(), "scry_souffle", "relations", "#{relation}_#{digest}.facts"])

    File.rm_rf!(facts)
    File.rm_rf!(store)
    File.mkdir_p!(store)

    assert {:ok, _outputs} = Scry.Analysis.souffle_solve(db, :mailbox)
    assert File.regular?(store)
  end
end
