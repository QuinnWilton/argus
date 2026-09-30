defmodule Mix.Tasks.Compile.ArgusManifestTest do
  @moduledoc """
  What a warm run trusts between runs, through the real chain: a warm
  run that executes nothing, the code versions an argus build moves, the
  schema entries a module read, the beam prefilter a touch passes, a
  manifest naming a query this graph does not define, and the manifest a
  corrupt write falls back from.

  In this module's peer (`Argus.Test.Peer`): the Mix project stack, the
  working directory, the code path and telemetry are VM-wide.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  import ExUnit.CaptureIO, only: [with_io: 2]

  alias Argus.Project.Scan
  alias Argus.Test.{Fixture, Peer}
  alias Mix.Tasks.Compile.Argus, as: CompileArgus
  alias Roux.Lang.Manifest
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
    %{copy: Path.join(System.tmp_dir!(), "argus_manifest_depot")}
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

  defp argus_diagnostics({_status, diagnostics}) do
    Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
  end

  defp counts_by_code(diagnostics) do
    diagnostics
    |> Enum.map(&code_of/1)
    |> Enum.frequencies()
  end

  defp code_of(%{message: message}) do
    case Regex.run(~r/^\[argus\.([a-z_]+)\]/, message) do
      [_, code] -> code
      nil -> :infrastructure
    end
  end

  # The keys the query log saw `query` execute on.
  defp ran(log, query), do: QueryLog.executions(log, query)

  test "a warm run executes nothing, and an edit re-extracts only its modules", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      compile!()

      QueryLog.reset(log)
      assert {:noop, _} = compile!()
      assert QueryLog.by_query(log, :execution) == %{}
      assert Enum.sort(QueryLog.hits(log, :located)) == [project: :coupling, project: :mailbox]

      queue = Path.join(copy, "lib/depot/queue.ex")
      edit!(queue, File.read!(queue) <> "\ndefmodule Depot.Extra, do: def(one, do: 1)\n")

      QueryLog.reset(log)
      compile!()

      # Queue's beam is rewritten with its code unchanged: equal once the
      # chunks extraction never reads are left out, so only the new
      # module is extracted.
      assert log |> ran(:module_facts) |> Enum.map(&Path.basename/1) ==
               ["Elixir.Depot.Extra.beam"]

      assert ran(log, :program_relations) == [:project]
    end)
  end

  # Rewrites the last run's manifest through `fun`, handed the database
  # it restores; returns what `fun` does.
  defp rewrite!(fun) do
    manifest = Argus.Driver.manifest_file()
    session = Argus.Graph.open(manifest: manifest)

    try do
      result = fun.(session.db)
      :ok = Manifest.write(session.db, session.sources, manifest)
      result
    after
      Roux.Session.close(session)
    end
  end

  # These fixtures deliberately replace a coherent historical entry. Keep the
  # other restored entries' proofs so the manifest still exercises warm reuse.
  defp put_kept(db, key, entry) do
    Roux.Dependencies.mutate(db, key, fn ->
      Roux.Memo.publish(db, key, entry, false, :restored)
    end)

    :ok
  end

  # As if the last run had computed `query`'s entries with other code: a
  # build of argus with an edit to the code the query runs.
  defp code_edited_since!(query) do
    rewrite!(fn db ->
      Roux.Memo.reduce_entries(db, :ok, fn
        {{^query, _key} = key, entry}, :ok ->
          put_kept(db, key, %{entry | code_version: "old"})

        _other, :ok ->
          :ok
      end)
    end)
  end

  # The producers extraction ran, per module, while `fun` runs.
  defp extracted(fun) do
    table = :ets.new(:extracted, [:public, :bag])
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:argus, :graph, :extraction_compute],
      &__MODULE__.record_extraction/4,
      table
    )

    try do
      result = fun.()
      {result, :ets.tab2list(table)}
    after
      :telemetry.detach(handler)
    end
  end

  @doc false
  def record_extraction(_event, _measurements, meta, table),
    do: :ets.insert(table, {meta.module, meta.producer})

  test "an edit to the producers' code re-runs every module, extracts nothing, solves nothing",
       %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Scan.scan(Argus.Config.load())
      code_edited_since!(:module_facts)

      QueryLog.reset(log)
      {warm, extracted} = extracted(&compile!/0)

      assert length(ran(log, :module_facts)) == map_size(modules)
      # Every producer's rows found by the module's trace.
      assert extracted == []

      # The same rows: nothing above them runs.
      assert ran(log, :module_semantic) == []
      assert ran(log, :solve) == []
      assert ran(log, :findings) == []
      assert counts_by_code(argus_diagnostics(warm)) == counts_by_code(argus_diagnostics(cold))
    end)
  end

  test "an edit to the findings' prose rebuilds the findings, and nothing else runs",
       %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      code_edited_since!(:findings)

      QueryLog.reset(log)
      warm = compile!()

      assert ran(log, :findings) == [project: :coupling, project: :mailbox]
      assert QueryLog.cutoffs(log, :findings) == ran(log, :findings)
      assert ran(log, :located) == []
      assert ran(log, :module_facts) == []
      assert ran(log, :solve) == []
      assert counts_by_code(argus_diagnostics(warm)) == counts_by_code(argus_diagnostics(cold))
    end)
  end

  test "a schema entry that moved re-runs the modules that read it, and extracts nothing",
       %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Scan.scan(Argus.Config.load())
      keys = for {_module, path} <- modules, do: Path.expand(path)

      # As if a relation had other columns when the last run extracted:
      # its entry's digest then, computed by the schema's code then. One
      # some modules read and others do not. A module's entry may name a
      # read more than once (its producers' trace observes it too), and
      # how often moves with what the run found kept: each module counts
      # once.
      {read, readers} =
        rewrite!(fn db ->
          reads =
            for key <- keys,
                {:ok, dependencies} = Roux.Memo.dependencies(db, {:module_facts, key}),
                {:schema_entry, _} = read <- dependencies,
                uniq: true,
                do: {read, key}

          {read, _} =
            reads
            |> Enum.group_by(&elem(&1, 0))
            |> Enum.find(fn {_read, by} -> length(by) < length(keys) end)

          {:ok, entry} = Roux.Memo.get(db, read)

          :ok =
            put_kept(db, read, %{
              entry
              | value: "before",
                hash: :erlang.phash2("before"),
                code_version: "old"
            })

          {read, for({^read, key} <- reads, do: key)}
        end)

      assert {:schema_entry, _} = read

      # Some modules, not every module.
      assert readers != []
      assert length(readers) < map_size(modules)

      QueryLog.reset(log)
      {warm, extracted} = extracted(&compile!/0)

      assert ran(log, :module_facts) == Enum.sort(readers)
      assert extracted == []
      assert ran(log, :module_semantic) == []
      assert ran(log, :solve) == []
      assert counts_by_code(argus_diagnostics(warm)) == counts_by_code(argus_diagnostics(cold))
    end)
  end

  test "a manifest naming a query this graph does not define is read as far as it holds", %{
    peer: peer,
    copy: copy
  } do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      cold = compile!()
      %{modules: modules} = Scan.scan(Argus.Config.load())

      # As a graph that kept each module's rows under a query this one
      # does not define left it: every module's semantic digest depends
      # on an entry of `producer_extraction`. Restoring drops that
      # query's entries, and validating a digest finds its dependency
      # gone: stale, and computed again.
      rewrite!(fn db ->
        for {_module, path} <- modules do
          key = Path.expand(path)
          producer = {:producer_extraction, {key, :base}}
          {:ok, facts} = Roux.Memo.get(db, {:module_facts, key})
          :ok = put_kept(db, producer, facts)
          {:ok, semantic} = Roux.Memo.get(db, {:module_semantic, key})
          :ok = put_kept(db, {:module_semantic, key}, %{semantic | dependencies: [producer]})
        end

        # And a :high input the next run sets back, so validation walks
        # every edge rather than skipping them on durability.
        :ok = Roux.Input.set(db, :project_root, :all, "/elsewhere")
      end)

      QueryLog.reset(log)
      warm = compile!()

      assert length(ran(log, :module_semantic)) == map_size(modules)
      assert counts_by_code(argus_diagnostics(warm)) == counts_by_code(argus_diagnostics(cold))

      # What it wrote holds nothing of the other query, and is read back.
      {:ok, data} = Manifest.load(Argus.Driver.manifest_file())

      refute Enum.any?(
               Manifest.memo_entries(data, Argus.Graph.store()),
               &match?({{:producer_extraction, _}, _}, &1)
             )

      QueryLog.reset(log)
      assert {:noop, _} = compile!()
      assert QueryLog.by_query(log, :execution) == %{}
    end)
  end

  test "--force starts cold; clean removes the state", %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      compile!()
      %{modules: modules} = Scan.scan(Argus.Config.load())

      QueryLog.reset(log)

      {{status, _diagnostics}, _stderr} =
        with_io(:stderr, fn -> Mix.Task.rerun("compile.argus", ["--force"]) end)

      assert status in [:ok, :noop]
      assert length(ran(log, :module_facts)) == map_size(modules)
      assert Enum.all?(CompileArgus.manifests(), &File.exists?/1)

      CompileArgus.clean()
      refute Enum.any?(CompileArgus.manifests(), &File.exists?/1)
    end)
  end

  test "touch without edit is a noop past the prefilter", %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      compile!()

      # Touch a beam directly (mtime moves, content identical): the sync
      # re-reads and re-hashes that one file, the input value compares
      # equal, and nothing downstream executes.
      beam = Path.join(Mix.Project.compile_path(), "Elixir.Depot.Queue.beam")
      File.touch!(beam, System.os_time(:second) + 5)

      QueryLog.reset(log)
      compile!()
      assert ran(log, :module_facts) == []
      assert ran(log, :solve) == []
    end)
  end

  test "corrupt manifest falls back to a clean cold build", %{peer: peer, copy: copy} do
    Fixture.checkout!(copy, @quick, :depot_quick)

    Fixture.in_peer(peer, copy, :depot_quick, fn log ->
      result = compile!()
      assert counts_by_code(argus_diagnostics(result)) != %{}

      File.write!(Argus.Driver.manifest_file(), "not a manifest")

      QueryLog.reset(log)
      result = compile!()

      # Full rebuild, same findings, no crash.
      assert counts_by_code(argus_diagnostics(result)) ==
               %{"coupling" => 1, "mailbox" => 2}

      assert ran(log, :module_facts) != []
    end)
  end
end
