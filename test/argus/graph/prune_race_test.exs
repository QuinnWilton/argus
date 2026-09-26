defmodule Argus.Graph.PruneRaceTest do
  @moduledoc """
  The scratch root is shared by every scry and planchette session with
  the same temporary directory, and each prunes it. A derivation or a
  solve writes its facts into a directory of its own, removed by it as
  it returns, so no prune — from another process of its VM or from
  another VM — takes a directory in use: only one whose owner died with
  it, once untouched for a day.

  In this module's peers (`Argus.Test.Peer`): `PATH` is VM-wide, and the
  scratch root these tests prune is a peer's own.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Graph, Peer}

  @moduletag :souffle
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup_all do
    %{paths: Graph.parity!(), peer: Peer.start!(), other: Peer.start!()}
  end

  # The real solver, holding stage 0 once it has written its outputs:
  # it names the facts directory it read, marks itself holding, and
  # waits to be told to go.
  defp holding_solver!(dir, marks) do
    real = System.find_executable("souffle")
    wrapper = Path.join(dir, "souffle")

    File.write!(wrapper, """
    #!/bin/sh
    case "$1" in --show*|--version) exec #{real} "$@";; esac
    facts=""
    prev=""
    last=""
    for arg in "$@"; do
      if [ "$prev" = "-F" ]; then facts="$arg"; fi
      prev="$arg"
      last="$arg"
    done
    #{real} "$@" || exit $?
    case "$last" in
      *stage0.dl)
        printf '%s' "$facts" > "#{marks}/facts"
        touch "#{marks}/holding"
        while [ ! -e "#{marks}/go" ]; do sleep 0.01; done ;;
    esac
    """)

    File.chmod!(wrapper, 0o755)
  end

  defp await_mark!(marks, mark, tries \\ 6_000) do
    cond do
      File.exists?(Path.join(marks, mark)) -> :ok
      tries == 0 -> flunk("never reached #{mark}")
      true -> Process.sleep(10) && await_mark!(marks, mark, tries - 1)
    end
  end

  test "a stage derivation keeps its directory through prunes from its VM and another", %{
    tmp_dir: dir,
    paths: paths,
    peer: peer,
    other: other
  } do
    marks = Path.join(dir, "marks")
    File.mkdir_p!(marks)
    # Whatever the test's outcome, no solver is left waiting.
    on_exit(fn -> File.write(Path.join(marks, "go"), "") end)

    tmp = Peer.run(peer, fn -> System.tmp_dir!() end)
    held = Task.async(fn -> Peer.run(peer, fn -> held_derivation(dir, marks, paths) end) end)

    # The derivation's own VM has pruned the root beside it; now another
    # VM with the same temporary directory does.
    await_mark!(marks, "pruned")

    :ok =
      Peer.run(other, fn ->
        System.put_env("TMPDIR", tmp)
        Argus.Graph.prune_scratch()
      end)

    File.write!(Path.join(marks, "go"), "")

    assert {:ok, call_edges} = Task.await(held, :infinity)
    assert call_edges > 0
  end

  # Stage 0 derived with the solver held once it has written its
  # outputs, while this VM prunes the scratch root from another process:
  # the number of call edges the stage came back with, or its error.
  defp held_derivation(dir, marks, paths) do
    db = Graph.new_db(Graph.use_parity!(paths))
    holding_solver!(dir, marks)
    original = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> original)

    try do
      derivation = Task.async(fn -> Argus.Graph.stage0_facts(db, :all) end)
      await_mark!(marks, "holding")
      facts = marks |> Path.join("facts") |> File.read!()

      # A derivation some minutes in, among directories newer than its
      # own, as a busy root holds: a window of the newest few would
      # leave it out.
      File.touch!(facts, System.os_time(:second) - 600)
      newer = for n <- 1..30, do: Path.join(Path.dirname(facts), "newer-#{n}")
      Enum.each(newer, &File.mkdir_p!/1)

      :ok = Argus.Graph.prune_scratch()
      File.write!(Path.join(marks, "pruned"), "")
      result = Task.await(derivation, :infinity)
      Enum.each(newer, &File.rm_rf!/1)

      # The derivation's directory is gone with it.
      refute File.exists?(facts)

      case result do
        {:ok, %{call_edge: edges}} -> {:ok, length(edges)}
        other -> other
      end
    after
      System.put_env("PATH", original)
    end
  end

  test "a relation store entry that is not the file is replaced", %{paths: paths, peer: peer} do
    Peer.run(peer, fn -> store_entry_replaced(paths) end)
  end

  defp store_entry_replaced(paths) do
    db = Graph.new_db(Graph.use_parity!(paths))
    {:ok, relations} = Argus.Graph.analysis_input_relations(db, :mailbox)
    staged = Argus.Analysis.stage0_relations() ++ Argus.Analysis.points_to_relations()
    relation = Enum.find(relations, &(Atom.to_string(&1) not in staged))
    digest = Argus.Graph.relation_digest(db, relation)

    # One of the files the solve links is replaced in the store by
    # something that cannot be linked or copied.
    store =
      Path.join([System.tmp_dir!(), "scry_scratch", "relations", "#{relation}_#{digest}.facts"])

    File.rm_rf!(store)
    File.mkdir_p!(store)

    assert {:ok, _outputs} = Argus.Graph.souffle_solve(db, :mailbox)
    assert File.regular?(store)
  end
end
