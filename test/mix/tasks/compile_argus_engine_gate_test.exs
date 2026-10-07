defmodule Mix.Tasks.Compile.ArgusEngineGateTest do
  @moduledoc """
  The engine gate: a machine without Rust, a failed solve and a failed
  stage 0, each against its own fixture checkout, in this module's peer
  (`Argus.Test.Peer`): `ARGUS_CARGO` and `ARGUS_FLOWLOG_DIR` are VM-wide,
  and here they move.
  """

  use ExUnit.Case, async: true
  @moduletag :project
  use Argus.Test.Peer

  alias Argus.Test.{Fixture, Peer}
  alias Roux.Lang.Manifest
  alias Roux.QueryLog

  @moduletag timeout: 300_000

  # The two analyses with findings on the fixture; both read stage 0.
  @quick [analyses: [:coupling, :mailbox]]

  # A store of the peer's own: a solve kept by another test would not
  # run the failing solver at all.
  setup_all do
    %{peer: Peer.start!(store: :own)}
  end

  # Each scenario needs its own app atom: in_project caches project
  # config by app name.
  defp checkout!(config, app) do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "argus_gate_#{app}"),
        Keyword.merge(@quick, config),
        app
      )

    {copy, app}
  end

  # Each scenario with a blob store of its own, for all its runs: the
  # same fixture's solves, kept by another scenario's run, would not run
  # the failing solver at all.
  defp in_project(peer, {copy, app}, fun) do
    Fixture.in_peer(peer, copy, app, fn log ->
      store = System.get_env("ARGUS_CACHE_DIR")
      System.put_env("ARGUS_CACHE_DIR", Path.join(copy, ".store"))

      try do
        fun.(log)
      after
        System.put_env("ARGUS_CACHE_DIR", store)
      end
    end)
  end

  defp compile!, do: Fixture.compile!()

  defp codes(diagnostics) do
    for %{message: message} <- diagnostics,
        [_, code] <- [Regex.run(~r/^\[argus\.([a-z_]+)\]/, message)],
        do: code
  end

  describe "engine gate" do
    @describetag :flowlog

    defp env(name, value, fun) do
      original = System.get_env(name)
      System.put_env(name, value)

      try do
        fun.()
      after
        if original, do: System.put_env(name, original), else: System.delete_env(name)
      end
    end

    # A cargo that is not there: argus cannot build an engine, nor run one
    # (`ARGUS_CARGO`, when set, is the only cargo it uses).
    defp without_rust(fun), do: env("ARGUS_CARGO", "/nonexistent/cargo", fun)

    defp with_failing_engine(program, fun), do: Argus.Test.FailingEngine.with(program, fun)

    defp manifest_entries do
      {:ok, manifest} = Manifest.load(Argus.Driver.manifest_file())
      Manifest.memo_entries(manifest, Argus.Graph.store())
    end

    defp manifest_keys, do: Enum.map(manifest_entries(), &elem(&1, 0))

    # An entry kept by digest in another store reads as missing here: no
    # error is, being transient.
    defp manifest_errors do
      for {key, %{value: {:error, _}}} <- manifest_entries(), do: key
    end

    test "a failed solve degrades once and is never replayed", %{peer: peer} do
      project = checkout!([], :depot_badsolve)

      in_project(peer, project, fn log ->
        with_failing_engine("analyses/mailbox.dl", fn ->
          {:ok, diagnostics} = compile!()
          diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))

          assert [degraded] = Enum.filter(diags, &(&1.message =~ "degraded"))
          assert degraded.message =~ "the mailbox analysis degraded"
          assert codes(diags) == ["coupling"]
        end)

        # The failure never reached the manifest...
        assert manifest_errors() == []

        # ...so the next run, with nothing edited and a working engine,
        # solves the analysis again instead of replaying the failure.
        QueryLog.reset(log)
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))

        assert Enum.sort(codes(diags)) == ["coupling", "mailbox", "mailbox"]

        assert QueryLog.executions(log, :solve) == [{:project, :mailbox}]
        assert QueryLog.executions(log, :extraction_pack) == []

        # And that success is persisted: a third run is a noop.
        QueryLog.reset(log)
        assert {:noop, _} = compile!()
        assert QueryLog.executions(log, :solve) == []
      end)
    end

    test "a failed stage 0 degrades the analyses that read it, and heals", %{peer: peer} do
      project = checkout!([], :depot_badstage0)

      in_project(peer, project, fn log ->
        with_failing_engine("stage0.dl", fn ->
          {:ok, diagnostics} = compile!()
          diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))

          # Every analysis reading the call graph degrades with the
          # stage's own reason, as a batch run's does.
          degraded = Enum.filter(diags, &(&1.message =~ "degraded"))
          assert length(degraded) == 2
          assert Enum.all?(degraded, &(&1.message =~ "injected failure"))
        end)

        assert manifest_errors() == []

        QueryLog.reset(log)
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
        assert length(diags) == 3
        assert {:project, :stage0} in QueryLog.executions(log, :stage)
      end)
    end

    @tag flowlog: false
    test "engine: :require makes a machine without Rust an error", %{peer: peer} do
      project = checkout!([engine: :require], :depot_require)

      in_project(peer, project, fn _log ->
        without_rust(fn ->
          assert {:error, diagnostics} = compile!()

          [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
          assert notice.severity == :error
          assert notice.message =~ "engine: :require"
        end)
      end)
    end
  end
end
