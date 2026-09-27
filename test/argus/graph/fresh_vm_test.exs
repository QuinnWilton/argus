defmodule Argus.Graph.FreshVmTest do
  @moduledoc """
  A module's facts extracted in one VM are found again in a fresh one
  through the store (`Argus.Graph.Pack`'s trace), with nothing extracted
  there: the trace holds no atom a fresh VM may not have made. A callee
  outside the program is one: its name is only in the caller's atom
  table, which nothing on the warm path reads, and `Roux.Blob` decodes
  a trace only when every atom in it exists.

  The callee's name is made at run time and only strings go to the
  peer: this module's own bytecode is loaded there, and a literal of it
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
