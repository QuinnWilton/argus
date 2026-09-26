defmodule Mix.Tasks.Compile.ArgusManifestTest do
  @moduledoc """
  What a warm run trusts between runs, through the real chain: the
  environment fingerprint an edit leaves alone, argus's code digests an
  argus edit moves, the beam prefilter a touch passes, and the manifest
  a corrupt write falls back from.

  In this module's peer (`Argus.Test.Peer`): the Mix project stack, the
  working directory, the code path and telemetry are VM-wide.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Roux.Lang.Manifest
  alias Argus.Test.{Fixture, Peer}
  alias Roux.QueryLog

  @moduletag timeout: 300_000
  @moduletag :souffle

  # The two analyses with findings on the fixture: these are about what
  # a warm run re-does, not about the default set's goldens (which
  # `Mix.Tasks.Compile.ArgusTest` pins).
  @quick [analyses: [:coupling, :mailbox]]

  setup_all do
    %{peer: Peer.start!()}
  end

  setup do
    %{copy: Path.join(System.tmp_dir!(), "scry_manifest_depot")}
  end

  defp compile!, do: Fixture.compile!()

  # Writes a fixture source and bumps its mtime forward: back-to-back
  # edits inside one posix second are invisible to :elixir's
  # second-granularity staleness check.
  defp edit!(path, content) do
    File.write!(path, content)

    bump = Process.get({__MODULE__, :bump}, 0) + 1
    Process.put({__MODULE__, :bump}, bump)
    File.touch!(path, System.os_time(:second) + bump)
  end

  defp scry_diagnostics({_status, diagnostics}) do
    Enum.filter(diagnostics, &(&1.compiler_name == "scry"))
  end

  defp counts_by_code(diagnostics) do
    diagnostics
    |> Enum.map(&code_of/1)
    |> Enum.frequencies()
  end

  defp code_of(%{message: message}) do
    case Regex.run(~r/^\[scry\.([a-z_]+)\]/, message) do
      [_, code] -> code
      nil -> :infrastructure
    end
  end

  # The environment digest is memoized per code path; a directory nobody
  # reads, put on the path for the call, makes it compute afresh — as the
  # next `mix compile`, a new VM, would.
  defp fresh_env(apps) do
    dir = Path.join(System.tmp_dir!(), "scry_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Code.append_path(dir)

    try do
      Argus.Graph.Environment.env(apps)
    after
      Code.delete_path(dir)
      File.rm_rf!(dir)
    end
  end

  test "an edit to the project leaves the environment fingerprint where it was", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn _log ->
      compile!()
      %{apps: apps} = Argus.Project.Scan.scan(Argus.Config.load())
      assert apps == [:depot_quick]
      before = fresh_env(apps)
      unwatched = fresh_env([])

      queue = Path.join(copy, "lib/depot/queue.ex")
      edit!(queue, File.read!(queue) <> "\ndefmodule Depot.Extra, do: def(one, do: 1)\n")
      compile!()

      # The project's beams moved (so a digest over them would), but the
      # scan tracks each of them itself: re-extracting every module on
      # every edit is what excluding them prevents.
      assert fresh_env([]) != unwatched
      assert fresh_env(apps) == before
    end)
  end

  # Rewrites the last run's manifest through `fun`, handed the database
  # it restores; returns what `fun` does.
  defp rewrite!(fun) do
    manifest = Argus.Driver.manifest_file()
    {:ok, data} = Manifest.load(manifest)
    db = Roux.Database.new()

    try do
      :ok = Roux.Lang.register_module(db, Argus.Graph.Frontend)
      :ok = Roux.Lang.register_module(db, Argus.Graph)
      :ok = Manifest.restore(db, data)
      result = fun.(db)
      :ok = Manifest.write(db, data.sources, manifest)
      result
    after
      Roux.Database.shutdown(db)
    end
  end

  # As if the last run had seen other argus code: `input` holds what it
  # recorded of it.
  defp argus_edited_since!(input) do
    rewrite!(&(:ok = Roux.Input.set(&1, input, :all, "before the edit")))
  end

  test "an edit to argus's producers re-extracts every module, and solves nothing it left",
       %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Argus.Project.Scan.scan(Argus.Config.load())
      argus_edited_since!(:extraction_code)

      QueryLog.reset(log)
      warm = compile!()

      assert QueryLog.executions(log, :module_extraction) == modules |> Map.keys() |> Enum.sort()

      # The same rows: nothing above them runs.
      assert QueryLog.executions(log, :module_semantic_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []
      assert QueryLog.executions(log, :findings) == []
      assert counts_by_code(scry_diagnostics(warm)) == counts_by_code(scry_diagnostics(cold))
    end)
  end

  test "an argus edit outside its producers rebuilds the findings, and extracts nothing",
       %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      argus_edited_since!(:argus_code)

      QueryLog.reset(log)
      warm = compile!()

      assert QueryLog.executions(log, :findings) == [:coupling, :mailbox]
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      # No schema entry moved: nothing was extracted ahead of the graph.
      assert QueryLog.hits(log, :program_relation_facts) == []
      assert counts_by_code(scry_diagnostics(warm)) == counts_by_code(scry_diagnostics(cold))
    end)
  end

  test "a schema entry that moved re-extracts the modules that read it, ahead of the graph",
       %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Argus.Project.Scan.scan(Argus.Config.load())
      read = {:schema_read, "columns supervisor"}

      # As if `supervisor` had other columns when the last run extracted:
      # its entry's digest then, and argus's code then.
      readers =
        Enum.sort(
          rewrite!(fn db ->
            {:ok, entry} = Roux.Memo.get(db, read)

            :ok =
              Roux.Memo.put(db, read, %{entry | value: "before", hash: :erlang.phash2("before")})

            :ok = Roux.Input.set(db, :argus_code, :all, "before the edit")

            for module <- Map.keys(modules),
                {:ok, dependencies} = Roux.Memo.dependencies(db, {:module_extraction, module}),
                read in dependencies,
                do: module
          end)
        )

      # The tree's modules, not every module.
      assert readers != []
      assert length(readers) < map_size(modules)

      QueryLog.reset(log)
      warm = compile!()

      assert QueryLog.executions(log, :module_extraction) == readers
      assert QueryLog.executions(log, :module_semantic_facts) == []
      assert QueryLog.executions(log, :souffle_solve) == []

      # Extracted before the graph asked for them: the runner took the
      # merged relations itself, where the extractions waited.
      assert QueryLog.hits(log, :program_relation_facts) == [:all]
      assert counts_by_code(scry_diagnostics(warm)) == counts_by_code(scry_diagnostics(cold))
    end)
  end

  defp memo_keys(query) do
    {:ok, data} = Manifest.load(Argus.Driver.manifest_file())

    for {{^query, key}, _entry} <- Manifest.memo_entries(data), do: key
  end

  test "a manifest another graph layout wrote is dropped, and the run is cold", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Argus.Project.Scan.scan(Argus.Config.load())
      modules = modules |> Map.keys() |> Enum.sort()

      # As a scry that memoized extraction per argus producer left it:
      # each module's rows under `producer_extraction`, a query this
      # graph does not define, which its semantic digest depends on; a
      # fingerprint of another shape; no layout. Validating a semantic
      # digest would run that query.
      rewrite!(fn db ->
        for module <- modules do
          producer = {:producer_extraction, {module, :base}}
          {:ok, extraction} = Roux.Memo.get(db, {:module_extraction, module})
          :ok = Roux.Memo.put(db, producer, extraction)
          :ok = Roux.Memo.delete(db, {:module_extraction, module})

          {:ok, semantic} = Roux.Memo.get(db, {:module_semantic_facts, module})

          :ok =
            Roux.Memo.put(db, {:module_semantic_facts, module}, %{
              semantic
              | dependencies: [producer]
            })
        end

        :ok = Roux.Input.set(db, :env_fingerprint, :all, %{elixir: "an older shape"})
        :ok = Roux.Memo.delete(db, {:input, :graph_layout, :all})
      end)

      QueryLog.reset(log)
      warm = compile!()

      # Cold, and right: every module extracted, every analysis solved.
      assert QueryLog.executions(log, :module_extraction) == modules
      assert QueryLog.executions(log, :souffle_solve) == [:coupling, :mailbox]
      assert counts_by_code(scry_diagnostics(warm)) == counts_by_code(scry_diagnostics(cold))

      # What it wrote holds nothing of the other layout, and is read back.
      assert memo_keys(:producer_extraction) == []
      QueryLog.reset(log)
      assert {:noop, _} = compile!()
      assert QueryLog.executions(log, :module_extraction) == []
    end)
  end

  test "argus keeps hashes and programs beside the manifest; --force drops them", %{
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)
    # A VM that has hashed nothing, as `mix compile` starts: one that has
    # keeps the hashes in memory and writes none.
    peer = Peer.start!()

    Fixture.in_peer(peer, copy, :depot_quick, fn _log ->
      compile!()

      # Scry's own dependencies are on the code path, outside OTP and
      # Elixir: their hashes are what the store keeps.
      ebins = Path.join(Argus.Driver.cache_dir(), "ebins")
      assert File.ls!(ebins) != []

      stale = Path.join(ebins, "stale-" <> String.duplicate("0", 64))
      File.write!(stale, "")

      # And what each program loads, which a warm run would start the
      # solver to ask.
      programs = Path.join(Argus.Driver.cache_dir(), "programs")
      assert Enum.any?(File.ls!(programs), &String.starts_with?(&1, "stage0-"))
      asked = Path.join(programs, "asked-" <> String.duplicate("0", 64))
      File.write!(asked, "")

      {{status, _diagnostics}, _stderr} =
        with_io(:stderr, fn -> Mix.Task.rerun("compile.argus", ["--force"]) end)

      assert status in [:ok, :noop]
      refute File.exists?(stale)
      refute File.exists?(asked)

      Mix.Tasks.Compile.Argus.clean()
      refute File.exists?(Argus.Driver.cache_dir())
    end)
  end

  test "a warm run validates the merged relations without serving them", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      compile!()
      queue = Path.join(copy, "lib/depot/queue.ex")

      # Nothing extracted ahead of the graph waits for the runner, so the
      # program's relations stay in the memo table: served, they would be
      # copied onto the runner's heap for nothing.
      QueryLog.reset(log)
      compile!()
      assert QueryLog.hits(log, :program_relation_facts) == []
      assert QueryLog.executions(log, :program_relation_facts) == []
      assert QueryLog.hits(log, :located) == [:coupling, :mailbox]

      # An edit prewarms its module, and the runner takes the relations
      # first, where the extraction waits.
      edit!(queue, File.read!(queue) <> "\ndefmodule Depot.Extra, do: def(one, do: 1)\n")
      QueryLog.reset(log)
      compile!()
      assert QueryLog.executions(log, :program_relation_facts) == [:all]
      assert Depot.Extra in QueryLog.executions(log, :module_extraction)
    end)
  end

  test "touch without edit is a noop past the prefilter", %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      compile!()

      # Touch a beam directly (mtime moves, content identical): the
      # scanner re-reads and re-hashes that one file, the input value
      # compares equal, and nothing downstream executes.
      beam = Path.join(Mix.Project.compile_path(), "Elixir.Depot.Queue.beam")
      File.touch!(beam, System.os_time(:second) + 5)

      QueryLog.reset(log)
      compile!()
      assert QueryLog.executions(log, :module_extraction) == []
      assert QueryLog.executions(log, :souffle_solve) == []
    end)
  end

  test "corrupt manifest falls back to a clean cold build", %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      result = compile!()
      assert counts_by_code(scry_diagnostics(result)) != %{}

      manifest = Path.join(Mix.Project.manifest_path(), "compile.scry")
      File.write!(manifest, "not a manifest")

      QueryLog.reset(log)
      result = compile!()

      # Full rebuild, same findings, no crash.
      assert counts_by_code(scry_diagnostics(result)) ==
               %{"coupling" => 1, "mailbox" => 2}

      assert QueryLog.executions(log, :module_extraction) != []
    end)
  end
end
