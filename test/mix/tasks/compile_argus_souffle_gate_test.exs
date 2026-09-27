defmodule Mix.Tasks.Compile.ArgusSouffleGateTest do
  @moduledoc """
  The souffle gate: a missing solver, a failed solve and a failed stage
  0, each against its own fixture checkout, in this module's peer
  (`Argus.Test.Peer`) — `PATH` is VM-wide, and here it moves.
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
  defp checkout!(scry_config, app) do
    copy =
      Fixture.checkout!(
        Path.join(System.tmp_dir!(), "scry_gate_#{app}"),
        Keyword.merge(@quick, scry_config),
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

  describe "souffle gate" do
    defp without_souffle(fun) do
      original = System.get_env("PATH")

      masked =
        original
        |> String.split(":")
        |> Enum.reject(fn dir ->
          souffle = Path.join(dir, "souffle")
          File.exists?(souffle)
        end)
        |> Enum.join(":")

      System.put_env("PATH", masked)

      try do
        fun.()
      after
        System.put_env("PATH", original)
      end
    end

    @tag :souffle
    test "souffle: :warn degrades with one notice and poisons nothing", %{peer: peer} do
      project = checkout!([], :depot_nosolver)

      in_project(peer, project, fn log ->
        without_souffle(fn ->
          assert {:ok, diagnostics} = compile!()

          [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
          assert notice.severity == :information
          assert notice.message =~ "souffle binary not found"
          assert QueryLog.executions(log, :solve) == []
        end)

        # No solve memo — not even an error one — reached the manifest.
        refute Enum.any?(manifest_keys(), &match?({:solve, _}, &1))

        # Souffle back on PATH: the solver input moves, analyses run, the
        # findings appear — the degraded run healed completely.
        assert {:ok, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
        assert length(diags) == 3
        assert QueryLog.executions(log, :solve) != []
      end)
    end

    # A souffle that fails whenever it runs a program whose path ends in
    # `failing` — but still answers `--version` and resolves a program's
    # inputs (`--show`), so only the run itself breaks.
    defp with_failing_souffle(failing, fun) do
      real = System.find_executable("souffle")

      dir =
        Path.join(System.tmp_dir!(), "scry_failing_souffle_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      wrapper = Path.join(dir, "souffle")

      File.write!(wrapper, """
      #!/bin/sh
      case "$1" in --show*|--version) exec #{real} "$@";; esac
      for arg in "$@"; do
        case "$arg" in *#{failing}) echo "injected failure" >&2; exit 1;; esac
      done
      exec #{real} "$@"
      """)

      File.chmod!(wrapper, 0o755)
      original = System.get_env("PATH")
      System.put_env("PATH", dir <> ":" <> original)

      try do
        fun.()
      after
        System.put_env("PATH", original)
      end
    end

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

    @tag :souffle
    test "a failed solve degrades once and is never replayed", %{peer: peer} do
      project = checkout!([], :depot_badsolve)

      in_project(peer, project, fn log ->
        with_failing_souffle("analyses/mailbox.dl", fn ->
          {:ok, diagnostics} = compile!()
          diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))

          assert [degraded] = Enum.filter(diags, &(&1.message =~ "degraded"))
          assert degraded.message =~ "the mailbox analysis degraded"
          assert codes(diags) == ["coupling"]
        end)

        # The failure never reached the manifest...
        assert manifest_errors() == []

        # ...so the next run, with nothing edited and a working solver,
        # solves the analysis again instead of replaying the failure.
        QueryLog.reset(log)
        {_status, diagnostics} = compile!()
        diags = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))

        assert Enum.sort(codes(diags)) == ["coupling", "mailbox", "mailbox"]

        assert QueryLog.executions(log, :solve) == [{:project, :mailbox}]
        assert QueryLog.executions(log, :module_facts) == []

        # And that success is persisted: a third run is a noop.
        QueryLog.reset(log)
        assert {:noop, _} = compile!()
        assert QueryLog.executions(log, :solve) == []
      end)
    end

    @tag :souffle
    test "a failed stage 0 degrades the analyses that read it, and heals", %{peer: peer} do
      project = checkout!([], :depot_badstage0)

      in_project(peer, project, fn log ->
        with_failing_souffle("stage0.dl", fn ->
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

    test "souffle: :require makes the missing solver an error", %{peer: peer} do
      project = checkout!([souffle: :require], :depot_require)

      in_project(peer, project, fn _log ->
        without_souffle(fn ->
          assert {:error, diagnostics} = compile!()

          [notice] = Enum.filter(diagnostics, &(&1.compiler_name == "argus"))
          assert notice.severity == :error
          assert notice.message =~ "souffle binary not found"
        end)
      end)
    end
  end
end
