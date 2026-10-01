defmodule Argus.Graph.SpecsSourceTest do
  @moduledoc """
  With a project's specs source (`Argus.Specs.Source`), the graph reads
  a callee's specs from the project's own dependencies, never from the
  code path, and keys that read on the directory it came from: the
  rebar3 fixture's telemetry is a stand-in at a version argus carries
  another of, with a function only it has.
  """

  # The query log counts executions across the node's databases.
  use ExUnit.Case, async: false

  alias Argus.Graph.{Extraction, Relations}
  alias Argus.Specs.Source
  alias Argus.Test.{Graph, Projects}
  alias Roux.QueryLog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Projects.synthesize!(:rebar3_app, Path.join(dir, "app"))
    {:ok, project} = Argus.Project.load(:rebar3, root)
    ledger = Path.join(root, "_build/default/lib/ledger/ebin/ledger.beam")
    telemetry = Path.join(root, "_build/default/checkouts/telemetry/ebin")

    %{source: Source.new(project), ledger: ledger, telemetry: Path.expand(telemetry)}
  end

  defp installed_telemetry(db) do
    for [":telemetry:" <> _ = func, _shape, "installed"] <-
          Relations.rows(db, :test, :spec_return),
        do: func
  end

  test "a callee's specs are the project's, not the code path's", %{
    source: source,
    ledger: ledger
  } do
    db = Graph.new_db(%{ledger: ledger}, specs_source: source)

    try do
      assert ":telemetry:fixture_version/0" in installed_telemetry(db)

      assert Roux.Runtime.query(db, :installed_specs, :telemetry) ==
               Argus.Specs.interface_digest(:telemetry, source)

      refute Roux.Runtime.query(db, :installed_specs, :telemetry) ==
               Argus.Specs.interface_digest(:telemetry)
    after
      Roux.Database.shutdown(db)
    end

    # Without the source, the code path's telemetry is argus's own.
    db = Graph.new_db(%{ledger: ledger})

    try do
      refute ":telemetry:fixture_version/0" in installed_telemetry(db)
    after
      Roux.Database.shutdown(db)
    end
  end

  test "a rebuilt dependency directory reads its specs again", %{
    source: source,
    ledger: ledger,
    telemetry: telemetry
  } do
    db = Graph.new_db(%{ledger: ledger}, specs_source: source, stamps: true)
    key = Path.expand(ledger)

    try do
      {:ok, _} = Extraction.module_facts(db, key)
      assert {:ok, deps} = Roux.Memo.dependencies(db, {:installed_specs, :telemetry})
      assert {:input, :app_code, telemetry} in deps

      log = QueryLog.start(db)

      try do
        :ok = Roux.Input.set(db, :app_code, telemetry, "telemetry rebuilt")
        {:ok, _} = Extraction.module_facts(db, key)

        assert :telemetry in QueryLog.executions(log, :installed_specs)
        # Its specs came out equal: the module is not extracted again.
        assert QueryLog.executions(log, :extraction_pack) == []
      after
        QueryLog.stop(log)
      end
    after
      Roux.Database.shutdown(db)
    end
  end
end
