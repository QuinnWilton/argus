defmodule Mix.Tasks.Compile.ScryManifestTest do
  @moduledoc """
  What a warm run trusts between runs, through the real chain: the
  environment fingerprint an edit leaves alone, argus's code digests an
  argus edit moves, the beam prefilter a touch passes, and the manifest
  a corrupt write falls back from.

  In this module's peer (`Scry.Test.Peer`): the Mix project stack, the
  working directory, the code path and telemetry are VM-wide.
  """

  use ExUnit.Case, async: true
  use Scry.Test.Peer

  alias Roux.Lang.Manifest
  alias Scry.Test.{Fixture, Peer, QueryLog}

  @moduletag timeout: 300_000
  @moduletag :souffle

  # The two analyses with findings on the fixture: these are about what
  # a warm run re-does, not about the default set's goldens (which
  # `Mix.Tasks.Compile.ScryTest` pins).
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
      Scry.Fingerprint.env(apps)
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
      %{apps: apps} = Scry.Scanner.scan(Scry.Config.load())
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
  # it restores.
  defp rewrite!(fun) do
    manifest = Scry.Runner.manifest_file()
    {:ok, data} = Manifest.load(manifest)
    db = Roux.Database.new()

    try do
      :ok = Roux.Lang.register_module(db, Scry.Frontend)
      :ok = Roux.Lang.register_module(db, Scry.Analysis)
      :ok = Manifest.restore(db, data)
      fun.(db)
      :ok = Manifest.write(db, data.sources, manifest)
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
      %{modules: modules} = Scry.Scanner.scan(Scry.Config.load())
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
      assert counts_by_code(scry_diagnostics(warm)) == counts_by_code(scry_diagnostics(cold))
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
               %{"coupling" => 2, "mailbox" => 3}

      assert QueryLog.executions(log, :module_extraction) != []
    end)
  end
end
