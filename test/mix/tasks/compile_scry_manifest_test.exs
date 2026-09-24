defmodule Mix.Tasks.Compile.ScryManifestTest do
  @moduledoc """
  What a warm run trusts between runs, through the real chain: the
  environment fingerprint an edit leaves alone, the beam prefilter a
  touch passes, and the manifest a corrupt write falls back from.

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

  # The specs extractor's digest, whose environment digest is memoized
  # per code path; a directory nobody reads, put on the path for the
  # call, makes it compute afresh — as the next `mix compile`, a new VM,
  # would.
  defp fresh_env(apps) do
    dir = Path.join(System.tmp_dir!(), "scry_env_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Code.append_path(dir)

    try do
      Scry.Fingerprint.producers([Argus.Extractors.Specs], apps)
    after
      Code.delete_path(dir)
      File.rm_rf!(dir)
    end
  end

  test "an edit to the project leaves the specs extractor's digest where it was", %{
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
      # scan tracks each of them itself: re-extracting every module's
      # specs on every edit is what excluding them prevents.
      assert fresh_env([]) != unwatched
      assert fresh_env(apps) == before
    end)
  end

  # Rewrites what the last run recorded of one producer's digest, as if
  # it had seen other code: with the stamp its digests hang on moved
  # too, as an edit to argus moves it, the next run takes the digest
  # again and finds it moved.
  defp edited_since!(producer) do
    rewrite!(fn db ->
      :ok = Roux.Input.set(db, :producer_digest, producer, %{code: "before", environment: nil})
      :ok = Roux.Input.set(db, :producer_stamp, :all, :before)
    end)
  end

  defp stored_input(input, key) do
    {:ok, data} = Manifest.load(Scry.Runner.manifest_file())

    Enum.find_value(Manifest.memo_entries(data), fn
      {{:input, ^input, ^key}, entry} -> {:ok, entry.value}
      _ -> nil
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

  defp memo_keys(query) do
    {:ok, data} = Manifest.load(Scry.Runner.manifest_file())

    for {{^query, key}, _entry} <- Manifest.memo_entries(data), do: key
  end

  test "producers' digests stand while nothing they run moved", %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      compile!()
      {:ok, taken} = stored_input(:producer_digest, Argus.Extractors.ETS)

      # A digest the last run recorded, with nothing it is a function of
      # moved since, is not taken again: this one would not survive it.
      stale = %{code: "recorded", environment: nil}
      rewrite!(&(:ok = Roux.Input.set(&1, :producer_digest, Argus.Extractors.ETS, stale)))

      compile!()
      assert stored_input(:producer_digest, Argus.Extractors.ETS) == {:ok, stale}

      # The stamp moved (argus's code, the runtime, the environment): taken
      # again, and the extractor runs again with it.
      rewrite!(&(:ok = Roux.Input.set(&1, :producer_stamp, :all, :moved)))

      QueryLog.reset(log)
      compile!()
      assert stored_input(:producer_digest, Argus.Extractors.ETS) == {:ok, taken}

      assert QueryLog.executions(log, :producer_extraction)
             |> Enum.map(&elem(&1, 1))
             |> Enum.uniq() ==
               [Argus.Extractors.ETS]
    end)
  end

  test "a manifest an older scry wrote keeps no joined copy of the facts", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn _log ->
      cold = compile!()
      %{modules: modules} = Scry.Scanner.scan(Scry.Config.load())

      # As an older scry left it: each module's facts joined and memoized
      # in `module_extraction`, which its semantic digest read, under a
      # fingerprint of another shape.
      rewrite!(fn db ->
        for module <- Map.keys(modules) do
          {:ok, _facts} = Scry.Analysis.module_extraction(db, module)
          {:ok, entry} = Roux.Memo.get(db, {:module_semantic_facts, module})
          deps = [{:module_extraction, module}]
          :ok = Roux.Memo.put(db, {:module_semantic_facts, module}, %{entry | dependencies: deps})
        end

        :ok = Roux.Input.set(db, :env_fingerprint, :all, %{older: :shape})
      end)

      assert length(memo_keys(:module_extraction)) == map_size(modules)

      warm = compile!()

      assert memo_keys(:module_extraction) == []
      assert counts_by_code(scry_diagnostics(warm)) == counts_by_code(scry_diagnostics(cold))
    end)
  end

  test "an edit to one argus extractor re-extracts that extractor alone", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Scry.Scanner.scan(Scry.Config.load())

      # The last run ran other ETS code: as if the extractor was edited
      # since.
      edited_since!(Argus.Extractors.ETS)

      QueryLog.reset(log)
      warm = compile!()

      assert Enum.sort(QueryLog.executions(log, :producer_extraction)) ==
               for(
                 module <- modules |> Map.keys() |> Enum.sort(),
                 do: {module, Argus.Extractors.ETS}
               )

      # Its rows came out the same: nothing above them runs.
      assert QueryLog.executions(log, :module_semantic_facts) == []
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
      assert QueryLog.extracted(log) == []
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

      assert QueryLog.extracted(log) != []
    end)
  end
end
