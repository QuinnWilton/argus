defmodule Argus.Graph.FreshVmTest do
  @moduledoc """
  A module's facts extracted in one VM are found again in a fresh one
  through the store (`Argus.Graph.Pack`'s trace), with nothing extracted
  there: the trace holds no atom a fresh VM may not have made. A callee
  outside the program is one: its name is only in the caller's atom
  table, which nothing on the warm path reads, and `Roux.Blob` decodes
  a trace only when every atom in it exists.

  So is a function a finding names, when its module was not extracted
  again: an edit that only moves another module's lines places the
  findings again from the kept ones, never building them anew.

  Those names are made at run time and only strings go to the peer:
  this module's own bytecode is loaded there, and a literal of one
  would make the atom.
  """

  use ExUnit.Case, async: true
  use Argus.Test.Peer

  alias Argus.Test.{Graph, Peer}

  @moduletag :project
  @moduletag :tmp_dir

  # A caller of `callee:go/0`, which nothing defines, compiled from forms.
  defp caller!(dir, callee) do
    forms = [
      {:attribute, 1, :module, :argus_fresh_vm_caller},
      {:attribute, 1, :export, [{:run, 0}]},
      {:function, 2, :run, 0,
       [{:clause, 2, [], [], [{:call, 2, {:remote, 2, {:atom, 2, callee}, {:atom, 2, :go}}, []}]}]}
    ]

    {:ok, :argus_fresh_vm_caller, beam} = :compile.forms(forms, [:debug_info])
    path = Path.join(dir, "argus_fresh_vm_caller.beam")
    File.write!(path, beam)
    path
  end

  test "a warm run in a fresh VM extracts nothing", %{tmp_dir: dir} do
    callee = String.to_atom("argus_fresh_vm_callee_#{System.unique_integer([:positive])}")
    path = caller!(dir, callee)
    store = Path.join(dir, "store")

    assert extracted(store, path) == [:argus_fresh_vm_caller]
    assert extracted(store, path) == []

    peer = Peer.start!()
    assert Peer.run(peer, fn -> extracted(store, path) end) == []
  end

  test "a line-only edit in a fresh VM places the kept findings again", %{tmp_dir: dir} do
    n = System.unique_integer([:positive])
    ebin = Path.join(dir, "ebin")
    File.mkdir_p!(ebin)
    compile!(dir, ebin, "a.ex", leak("A#{n}", "leak_a_#{n}", 0))
    compile!(dir, ebin, "b.ex", leak("B#{n}", "leak_b_#{n}", 0))
    beams = ebin |> Path.join("*.beam") |> Path.wildcard() |> Enum.sort()
    state = %{store: Path.join(dir, "store"), manifest: Path.join(dir, "manifest"), beams: beams}

    cold = session_run(state)
    assert [{"a.ex", a_line}, {"b.ex", b_line}] = cold.places
    assert cold.findings != []

    # Every line of B moves down by three; A is as it was.
    compile!(dir, ebin, "b.ex", leak("B#{n}", "leak_b_#{n}", 3))

    peer = Peer.start!()
    warm = Peer.run(peer, fn -> session_run(state) end)

    assert warm.places == [{"a.ex", a_line}, {"b.ex", b_line + 3}]
    assert [b] = warm.extracted
    assert String.ends_with?(b, "B#{n}.beam")
    assert warm.located != []
    assert warm.findings == []
  end

  # A module whose function starts a task it never awaits, `blank` lines
  # below the top of its file.
  defp leak(module, function, blank) do
    String.duplicate("\n", blank) <>
      """
      defmodule ArgusFreshVm.#{module} do
        def #{function}(x) do
          Task.async(fn -> x end)
          :ok
        end
      end
      """
  end

  defp compile!(dir, ebin, name, code) do
    source = Path.join(dir, name)
    File.write!(source, code)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      {:ok, modules, _warnings} =
        Kernel.ParallelCompiler.compile_to_path([source], ebin, return_diagnostics: true)

      for module <- modules do
        :code.purge(module)
        :code.delete(module)
        :code.purge(module)
      end
    end)
  end

  # A kept session over the beams, as the driver runs one: mailbox's
  # placed findings (each one's file and line), and the keys `findings`,
  # `located` and `module_facts` ran on.
  defp session_run(%{store: store, manifest: manifest, beams: beams}) do
    session = Argus.Graph.open(store: Roux.Blob.open!(store), manifest: manifest)
    db = session.db
    log = Roux.QueryLog.start(db)

    try do
      files = Map.new(beams, &{&1, &1})

      %{meta: meta} =
        Roux.Sources.sync(db, :beam, files, session.sources,
          hash: &Argus.Graph.hash/1,
          value: fn %{hash: hash} -> %{hash: hash} end
        )

      :ok = Roux.Input.set(db, :program, :fresh, beams)
      _moved = Argus.Graph.set_environment(db, stamps: false)
      :ok = Argus.Graph.set_priors(db, :fresh, :off)
      %{mailbox: {:ok, located}} = Argus.Graph.located(db, :fresh, [:mailbox])
      {_status, _session} = Roux.Session.commit(session, meta)

      %{
        places: located |> Enum.map(&{Path.basename(&1.file), &1.line}) |> Enum.sort(),
        extracted: Roux.QueryLog.executions(log, :module_facts),
        located: Roux.QueryLog.executions(log, :located),
        findings: Roux.QueryLog.executions(log, :findings)
      }
    after
      Roux.QueryLog.stop(log)
      Roux.Session.close(session)
    end
  end

  # The modules whose producers ran for the program of `path`, over the
  # store at `store`.
  defp extracted(store, path) do
    table = :ets.new(:extracted, [:public, :bag])
    handler = "fresh-vm-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:argus, :graph, :extract],
        &__MODULE__.record/4,
        table
      )

    db = Graph.new_db(%{caller: path}, store: Roux.Blob.open!(store))

    try do
      {:ok, _} = Argus.Graph.Extraction.module_facts(db, Path.expand(path))
      for {module} <- :ets.tab2list(table), do: module
    after
      :telemetry.detach(handler)
      Roux.Database.shutdown(db)
    end
  end

  @doc false
  def record(_event, _measurements, meta, table), do: :ets.insert(table, {meta.module})
end
